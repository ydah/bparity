# frozen_string_literal: true

require "date"

module Bparity
  module Adapter
    Operation = Struct.new(:name, :invoker, :return_mapper, :error_mapper, keyword_init: true) do
      def invoke(subject, args, kwargs, &block)
        return invoker.call(subject, args, kwargs, &block) if invoker

        subject.public_send(name.delete_prefix("#"), *args, **kwargs, &block)
      end

      def map_return(value) = return_mapper ? return_mapper.call(value) : value

      def map_error(error)
        error_mapper ? error_mapper.call(error) : { class: error.class.name, message: Bparity.exception_message(error) }
      end
    end

    class OperationDsl
      def initialize(operation)
        @operation = operation
      end

      def invoke(&block) = @operation.invoker = block
      def map_return(&block) = @operation.return_mapper = block
      def map_error(&block) = @operation.error_mapper = block
    end

    class Subject
      attr_reader :name, :operations
      attr_accessor :constructor, :state_projection

      def initialize(name)
        @name = name
        @operations = {}
      end

      def construct(&block) = self.constructor = block
      def state(&block) = self.state_projection = block

      def operation(name, &block)
        item = Operation.new(name: name)
        OperationDsl.new(item).instance_eval(&block) if block
        operations[name] = item
      end

      def build(context = {})
        unless constructor
          raise ConfigurationError, "Adapter subject #{name} has no constructor. Add a construct block to the adapter."
        end

        constructor.call(context)
      end
    end

    Waiver = Struct.new(:id, :reason, :approved_by, :approved_at, keyword_init: true)

    class External
      attr_reader :source, :target, :call_mappers

      def initialize(source, target)
        @source = source
        @target = target
        @call_mappers = {}
      end

      def map_call(name, &block)
        call_mappers[name.to_s] = block
      end
    end

    class Definition
      attr_reader :spec, :subjects, :waivers, :externals

      def initialize(spec: nil)
        @spec = spec
        @subjects = {}
        @waivers = {}
        @externals = []
      end

      def subject(name, &block)
        item = Subject.new(name)
        item.instance_eval(&block) if block
        subjects[name] = item
      end

      def waive(id, reason:, approved_by:, approved_at:)
        values = { "id" => id, "reason" => reason, "approved_by" => approved_by, "approved_at" => approved_at }
        missing = values.filter_map { |name, value| name if value.to_s.strip.empty? }
        unless missing.empty?
          raise ConfigurationError,
                "Waiver metadata is missing #{missing.join(', ')}. Add an ID, reason, approver, and approval date."
        end
        begin
          Date.iso8601(approved_at.to_s)
        rescue Date::Error
          raise ConfigurationError,
                "Waiver #{id} has an invalid approval date. Use YYYY-MM-DD."
        end

        waivers[id] = Waiver.new(id:, reason:, approved_by:, approved_at:)
      end

      def external(mapping, &block)
        source, target = mapping.first
        item = External.new(source, target)
        item.instance_eval(&block) if block
        externals << item
      end
    end
  end
end
