# frozen_string_literal: true

require "digest"
require "fileutils"
require "time"

module Bparity
  module Recording
    module Context
      module_function

      def external_stack = Thread.current[:bparity_external_stack] ||= []
      def append_external(call) = external_stack.last&.push(call)
    end

    module Serializer
      module_function

      def dump(value, projections: {})
        projection = projections[value.class.name]
        return dump(projection.call(value), projections:) if projection

        case value
        when nil, true, false, String, Integer then value
        when Float then value.finite? ? value : { "$float" => value.to_s }
        when Symbol then { "$symbol" => value.to_s }
        when Time then { "$time" => value.utc.iso8601(9) }
        when Array then value.map { |item| dump(item, projections:) }
        when Hash
          { "$hash" => value.map { |key, item| [dump(key, projections:), dump(item, projections:)] } }
        else
          dump_object(value, projections)
        end
      rescue StandardError
        { "$unserializable" => value.class.name, "$digest" => Digest::SHA256.hexdigest(value.inspect) }
      end

      def load(value)
        return value.map { |item| load(item) } if value.is_a?(Array)
        return value unless value.is_a?(Hash)
        return value["$symbol"].to_sym if value.key?("$symbol")
        return Time.iso8601(value["$time"]) if value.key?("$time")
        return Float(value["$float"]) if value.key?("$float")
        return value["$hash"].to_h { |key, item| [load(key), load(item)] } if value.key?("$hash")

        value.transform_values { |item| load(item) }
      end

      def dump_object(value, projections)
        readers = value.class.public_instance_methods(false).select do |name|
          value.method(name).arity.zero? && !%i[to_s inspect hash].include?(name)
        end
        attributes = readers.sort.to_h { |name| [name.to_s, dump(value.public_send(name), projections:)] }
        return { "$class" => value.class.name, "$attributes" => attributes } unless attributes.empty?

        { "$unserializable" => value.class.name, "$digest" => Digest::SHA256.hexdigest(value.inspect) }
      end
      private_class_method :dump_object
    end

    class Canonicalizer
      UUID = /\b[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\b/i

      def initialize(config = {})
        @config = config
        @ids = {}
      end

      def call(value)
        case value
        when String then canonical_string(value)
        when Array then value.map { |item| call(item) }
        when Hash then value.to_h { |key, item| [key, call(item)] }
        else value
        end
      end

      private

      def canonical_string(value)
        return value unless @config[:uuid_placeholder]

        value.gsub(UUID) { |id| @ids[id] ||= "<ID:#{@ids.length}>" }
      end
    end

    class Recorder
      attr_reader :writer

      def initialize(boundary:, writer:)
        @boundary = boundary
        @writer = writer
        @sequence = 0
        @canonicalizer = Canonicalizer.new(boundary.canonicalization)
      end

      def install!
        @boundary.subjects.each_value { |subject| install_subject(subject) }
        @boundary.externals.each_value { |external| install_external(external) }
        self
      end

      def capture(subject, receiver, operation, args, kwargs, block)
        projections = subject.return_projections
        before_args = Serializer.dump(args)
        yields = []
        wrapped = block && proc { |*items|
          yields << Serializer.dump(items)
          block.call(*items)
        }
        pre_state = project_state(subject, receiver)
        Context.external_stack << []
        outcome = yield(wrapped)
        serialized = Serializer.dump(outcome, projections:)
        external_calls = Context.external_stack.pop
        write(subject, receiver, operation, args, kwargs, before_args, yields, pre_state, block, external_calls,
              result_value: serialized)
        outcome
      rescue Exception => e # rubocop:disable Lint/RescueException -- recording must preserve every observable exception
        external_calls = Context.external_stack.pop || []
        write(subject, receiver, operation, args, kwargs, before_args, yields, pre_state, block, external_calls,
              error: { "class" => e.class.name, "message" => e.message, "cause" => e.cause&.class&.name })
        raise
      end

      private

      def install_subject(subject)
        target = Bparity.constantize(subject.name)
        recorder = self
        mod = Module.new
        subject.observed_methods(target).each do |method_name|
          mod.define_method(method_name) do |*args, **kwargs, &block|
            recorder.capture(subject, self, method_name, args, kwargs, block) do |wrapped|
              super(*args, **kwargs, &wrapped || block)
            end
          end
        end
        target.prepend(mod)
      end

      def install_external(external)
        target = Bparity.constantize(external.name)
        mod = Module.new
        methods = external.method_names.empty? ? target.public_instance_methods(false) : external.method_names
        methods.each do |method_name|
          mod.define_method(method_name) do |*args, **kwargs, &block|
            value = super(*args, **kwargs, &block)
            Context.append_external({ "target" => external.name, "method" => method_name.to_s,
                                      "args" => Serializer.dump(args), "kwargs" => Serializer.dump(kwargs),
                                      "outcome" => { "kind" => "return", "value" => Serializer.dump(value) } })
            value
          rescue StandardError => e
            Context.append_external({ "target" => external.name, "method" => method_name.to_s,
                                      "args" => Serializer.dump(args), "kwargs" => Serializer.dump(kwargs),
                                      "outcome" => { "kind" => "raise", "class" => e.class.name,
                                                     "message" => e.message } })
            raise
          end
        end
        target.prepend(mod)
      end

      def write(subject, receiver, operation, args, kwargs, before_args, yields, pre_state, block, external_calls,
                result_value: nil, error: nil)
        @sequence += 1
        writer.write(@canonicalizer.call({
                                           "id" => format("bc-%06d", @sequence), "seq" => @sequence,
                                           "subject" => subject.name,
                                           "operation" => "##{operation}", "provenance" => provenance,
                                           "pre_state" => pre_state, "args" => Serializer.dump(args),
                                           "kwargs" => Serializer.dump(kwargs),
                                           "block_given" => !block.nil?, "yields" => yields,
                                           "outcome" => outcome(error, result_value),
                                           "post_state" => project_state(subject, receiver),
                                           "external_calls" => external_calls,
                                           "mutated_args" => mutated_indices(before_args, Serializer.dump(args))
                                         }))
      end

      def mutated_indices(before, after)
        [before.length, after.length].max.times.reject { |index| before[index] == after[index] }
      end

      def outcome(error, result_value)
        return { "kind" => "raise", **error } if error

        { "kind" => "return", "value" => result_value }
      end

      def project_state(subject, receiver)
        Serializer.dump(subject.state_projection&.call(receiver))
      end

      def provenance
        example = defined?(RSpec) && RSpec.respond_to?(:current_example) && RSpec.current_example
        unless example
          return { "example_id" => nil, "description" => nil,
                   "location" => caller_locations(4, 1).first.to_s }
        end

        { "example_id" => example.id, "description" => example.full_description,
          "location" => example.metadata[:location] }
      end
    end
  end
end
