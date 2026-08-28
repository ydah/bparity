# frozen_string_literal: true

require "digest"
require "fileutils"
require "time"
require "coverage"
require "date"

module Bparity
  module Recording
    module Context
      module_function

      def external_stack = Thread.current[:bparity_external_stack] ||= []
      def append_external(call) = external_stack.last&.push(call)
      def provenance = Thread.current[:bparity_provenance]

      def provenance=(value)
        Thread.current[:bparity_provenance] = value
      end
    end

    module Serializer
      module_function

      def dump(value, projections: {}, seen: nil)
        seen ||= {}.compare_by_identity
        projection = projections[value.class.name]
        if projection
          return { "$unserializable" => value.class.name, "$reason" => "cyclic projection" } if seen.key?(value)

          return dump(projection.call(value), projections:, seen: with_seen(seen, value))
        end

        if recursive?(value)
          return { "$unserializable" => value.class.name, "$reason" => "cyclic reference" } if seen.key?(value)

          seen = with_seen(seen, value)
        end

        case value
        when nil, true, false, String, Integer then value
        when Float then value.finite? ? value : { "$float" => value.to_s }
        when Symbol then { "$symbol" => value.to_s }
        when Time then { "$time" => value.utc.iso8601(9) }
        when Array then value.map { |item| dump(item, projections:, seen:) }
        when Hash
          { "$hash" => value.map do |key, item|
            [dump(key, projections:, seen:), dump(item, projections:, seen:)]
          end }
        else
          dump_object(value, projections, seen)
        end
      rescue StandardError
        { "$unserializable" => value.class.name, "$digest" => safe_digest(value) }
      end

      def load(value)
        return value.map { |item| load(item) } if value.is_a?(Array)
        return value unless value.is_a?(Hash)
        return value["$symbol"].to_sym if value.key?("$symbol")
        return Time.iso8601(value["$time"]) if value.key?("$time")
        return Float(value["$float"]) if value.key?("$float")
        return value["$hash"].to_h { |key, item| [load(key), load(item)] } if value.key?("$hash")
        return load_object(value) if value.key?("$class") && value.key?("$ivars")

        value.transform_values { |item| load(item) }
      end

      def load_object(value)
        klass = Bparity.constantize(value.fetch("$class"))
        klass.allocate.tap do |object|
          value.fetch("$ivars").each do |name, item|
            object.instance_variable_set(name, load(item))
          end
        end
      rescue ConfigurationError, TypeError
        value.transform_values { |item| load(item) }
      end
      private_class_method :load_object

      def dump_object(value, projections, seen)
        ivars = value.instance_variables.sort.to_h do |name|
          [name.to_s, dump(value.instance_variable_get(name), projections:, seen:)]
        end
        return { "$class" => value.class.name, "$ivars" => ivars } unless ivars.empty?

        readers = value.class.public_instance_methods(false).select do |name|
          value.method(name).arity.zero? && !%i[to_s inspect hash].include?(name)
        end
        attributes = readers.sort.to_h do |name|
          [name.to_s, dump(value.public_send(name), projections:, seen:)]
        end
        return { "$class" => value.class.name, "$attributes" => attributes } unless attributes.empty?

        { "$unserializable" => value.class.name, "$digest" => safe_digest(value) }
      end
      private_class_method :dump_object

      def recursive?(value) = value.is_a?(Array) || value.is_a?(Hash) || !primitive?(value)
      private_class_method :recursive?

      def primitive?(value)
        value.nil? || value.equal?(true) || value.equal?(false) || value.is_a?(String) || value.is_a?(Numeric) ||
          value.is_a?(Symbol) || value.is_a?(Time)
      end
      private_class_method :primitive?

      def with_seen(seen, value)
        copy = seen.dup
        copy.compare_by_identity
        copy[value] = true
        copy
      end
      private_class_method :with_seen

      def safe_digest(value)
        Digest::SHA256.hexdigest(value.inspect)
      rescue Exception # rubocop:disable Lint/RescueException -- this is the terminal serializer fallback
        Digest::SHA256.hexdigest(value.class.name)
      end
      private_class_method :safe_digest
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
        when Float then canonical_float(value)
        when Array then value.map { |item| call(item) }
        when Hash
          return { "$time" => @config[:freeze_time] } if value.key?("$time") && @config[:freeze_time]

          value.to_h { |key, item| [key, call(item)] }
        else value
        end
      end

      private

      def canonical_string(value)
        return value unless @config[:uuid_placeholder]

        value.gsub(UUID) { |id| @ids[id] ||= "<ID:#{@ids.length}>" }
      end

      def canonical_float(value)
        tolerance = @config[:float_tolerance]
        if tolerance && !tolerance.positive?
          raise ConfigurationError, "Float tolerance must be positive. Update the boundary configuration."
        end

        tolerance ? (value / tolerance).round * tolerance : value
      end
    end

    module Determinism
      TIME_KEY = :bparity_frozen_time
      RANDOM_KEY = :bparity_previous_random_seed

      module_function

      def apply(config)
        Thread.current[RANDOM_KEY] = srand(config[:random_seed]) if config[:random_seed]
        return unless config[:freeze_time]

        install_time_hook
        install_date_hook
        Thread.current[TIME_KEY] = Time.parse(config[:freeze_time].to_s)
      rescue ArgumentError
        raise ConfigurationError, "Frozen time is invalid. Use an ISO 8601 value in the boundary configuration."
      end

      def clear
        Thread.current[TIME_KEY] = nil
        previous_seed = Thread.current[RANDOM_KEY]
        srand(previous_seed) if previous_seed
        Thread.current[RANDOM_KEY] = nil
      end

      def install_time_hook
        return if Time.singleton_class.instance_variable_defined?(:@bparity_time_hook)

        key = TIME_KEY
        Time.singleton_class.prepend(Module.new do
          define_method(:now) { |*args, **kwargs| Thread.current[key] || super(*args, **kwargs) }
        end)
        Time.singleton_class.instance_variable_set(:@bparity_time_hook, true)
      end
      private_class_method :install_time_hook

      def install_date_hook
        return if Date.singleton_class.instance_variable_defined?(:@bparity_date_hook)

        key = TIME_KEY
        Date.singleton_class.prepend(Module.new do
          define_method(:today) { Thread.current[key]&.to_date || super() }
        end)
        Date.singleton_class.instance_variable_set(:@bparity_date_hook, true)
      end
      private_class_method :install_date_hook
    end

    module CoverageTracker
      module_function

      def running? = Coverage.running?

      def start
        return if Coverage.running?

        Coverage.start(lines: true, branches: true)
      end

      def finish(path)
        return unless Coverage.running?

        root = "#{File.expand_path(Dir.pwd)}#{File::SEPARATOR}"
        files = Coverage.result.filter_map do |file, data|
          next unless File.expand_path(file).start_with?(root)

          branches = data.fetch(:branches, {}).flat_map do |_base, children|
            children.map do |location, count|
              { "type" => location[0].to_s, "start_line" => location[2],
                "end_line" => location[4], "count" => count }
            end
          end
          { "path" => file, "lines" => data.fetch(:lines, []), "branches" => branches }
        end
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, JSON.pretty_generate("files" => files))
      end

      def gaps(path, source_paths: [])
        allowed = source_paths.map { |source| File.expand_path(source) }
        JSON.parse(File.read(path)).fetch("files").flat_map do |file|
          next [] unless allowed.empty? || allowed.include?(File.expand_path(file.fetch("path")))

          file.fetch("branches").filter_map do |branch|
            next unless branch.fetch("count").zero?

            { "kind" => "uncovered_branch", "location" => "#{file.fetch('path')}:#{branch.fetch('start_line')}" }
          end
        end
      rescue Errno::ENOENT
        raise ConfigurationError, "Cannot read coverage file #{path}. Run `bparity record` first."
      rescue JSON::ParserError, KeyError
        raise ConfigurationError, "Coverage file #{path} is invalid. Run `bparity record` again."
      end
    end

    module MinitestDriver
      module_function

      def install!
        return if Minitest::Test < TestHook

        Minitest::Test.prepend(TestHook)
      end

      module TestHook
        def run
          location = method(name).source_location&.join(":")
          Context.provenance = { "example_id" => "#{self.class}##{name}", "description" => name,
                                 "location" => location }
          super
        ensure
          Context.provenance = nil
        end
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
              error: { "class" => e.class.name, "message" => Bparity.exception_message(e),
                       "cause" => e.cause&.class&.name })
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
                                                     "message" => Bparity.exception_message(e) } })
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
                                           "canonicalization" => @boundary.canonicalization.transform_keys(&:to_s),
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
        return Context.provenance if Context.provenance
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
