# frozen_string_literal: true

module Bparity
  module Boundary
    Subject = Struct.new(:name, :method_names, :excluded, :state_projection, :return_projections, keyword_init: true) do
      def initialize(name:, **)
        super(name:, method_names: [], excluded: [], return_projections: {})
      end

      def methods(*names)
        self.method_names = names.map(&:to_sym)
      end

      def exclude(*names)
        self.excluded |= names.map(&:to_sym)
      end

      def state(&block)
        self.state_projection = block
      end

      def project_return(class_name, &block)
        return_projections[class_name] = block
      end

      def observed_methods(target)
        (method_names.empty? ? target.public_instance_methods(false) : method_names) - excluded
      end
    end

    External = Struct.new(:name, :method_names, keyword_init: true) do
      def initialize(name:, **)
        super(name:, method_names: [])
      end

      def methods(*names)
        self.method_names = names.map(&:to_sym)
      end
    end

    class Definition
      attr_reader :subjects, :externals, :canonicalization, :driver_config, :formal_config

      def initialize
        @subjects = {}
        @externals = {}
        @canonicalization = {}
        @formal_config = {}
      end

      def observe(name, &block)
        subject = Subject.new(name: name)
        subject.instance_eval(&block) if block
        subjects[name] = subject
      end

      def external(name, &block)
        item = External.new(name: name)
        item.instance_eval(&block) if block
        externals[name] = item
      end

      def canonicalize(&)
        CanonicalizationDsl.new(canonicalization).instance_eval(&)
      end

      def driver(name, **options)
        @driver_config = { name: name.to_sym, **options }
      end

      def formal(&)
        FormalDsl.new(formal_config).instance_eval(&)
      end
    end

    class CanonicalizationDsl
      def initialize(config)
        @config = config
      end

      def freeze_time(value) = @config[:freeze_time] = value
      def random_seed(value) = @config[:random_seed] = value
      def uuid_placeholder(value) = @config[:uuid_placeholder] = value
      def float_tolerance(value) = @config[:float_tolerance] = value
    end

    class FormalDsl
      def initialize(config)
        @config = config
      end

      def pure_fragment(name) = (@config[:pure_fragments] ||= []) << name
      def bounded_scope(**scope) = @config[:bounded_scope] = scope
      def lts_learning(mode) = @config[:lts_learning] = mode
    end
  end
end
