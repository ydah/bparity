# frozen_string_literal: true

require "prism"

module Bparity
  module Formal
    module Assumptions
      CATALOG = [
        { id: :h1, name: "world_freeze", enforcement: "runtime snapshot" },
        { id: :h2, name: "dynamic_methods_declared", enforcement: "discovery" },
        { id: :h3, name: "no_dynamic_evaluation", enforcement: "Prism static analysis" },
        { id: :h4, name: "runtime_identity_unobserved", enforcement: "serializer" },
        { id: :h5, name: "ieee_754", enforcement: "declaration only" },
        { id: :h6, name: "exceptions_are_outputs", enforcement: "recorder" },
        { id: :h7, name: "single_thread", enforcement: "declaration only" }
      ].freeze

      class WorldFreeze
        def initialize(classes)
          @classes = classes
        end

        def check
          before = fingerprint
          value = yield
          violations = before == fingerprint ? [] : ["H1: a target class changed during verification"]
          [value, violations]
        end

        private

        def fingerprint
          @classes.to_h do |klass|
            methods = klass.instance_methods(false).sort.to_h do |name|
              method = klass.instance_method(name)
              [name, [method.owner.name, method.source_location, method.hash]]
            end
            [klass.name, [klass.ancestors.map(&:name), methods]]
          end
        end
      end

      class DynamicCodeDetector
        FORBIDDEN = %i[eval binding class_eval module_eval instance_eval].freeze

        def scan(paths)
          Array(paths).flat_map { |path| scan_file(path) }
        end

        private

        def scan_file(path)
          result = Prism.parse_file(path)
          return [{ "assumption" => "H3", "location" => path, "reason" => "syntax error" }] unless result.success?

          nodes(result.value).filter_map do |node|
            next unless forbidden?(node)

            { "assumption" => "H3", "location" => "#{path}:#{node.location.start_line}",
              "reason" => "dynamic call #{node.name}" }
          end
        end

        def forbidden?(node)
          return false unless node.type == :call_node
          return true if FORBIDDEN.include?(node.name)
          return false unless node.name == :send

          argument = node.arguments&.arguments&.first
          !argument || argument.type != :symbol_node
        end

        def nodes(root, &)
          return enum_for(__method__, root) unless block_given?

          yield root
          root.compact_child_nodes.each { |child| nodes(child, &) }
        end
      end
    end
  end
end
