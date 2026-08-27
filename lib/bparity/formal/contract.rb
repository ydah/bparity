# frozen_string_literal: true

require "prism"

module Bparity
  module Formal
    class ContractCompiler
      VARIABLES = %i[result args kwargs pre_state post_state].freeze
      CONSTANTS = { "Array" => Array, "Hash" => Hash, "String" => String, "Integer" => Integer,
                    "Float" => Float, "Symbol" => Symbol, "NilClass" => NilClass }.freeze
      CALLS = %i[== != > >= < <= + - * / % [] size length nil? empty? is_a? between? match?
                 start_with? end_with? include? uniq sort].freeze

      def compile(expression)
        source = expression.gsub(/\breturn\b/, "result")
        prefix = VARIABLES.map { |name| "#{name} = nil" }.join("; ")
        parsed = Prism.parse("#{prefix}; #{source}")
        unless parsed.success?
          raise ConfigurationError,
                "Invalid contract expression: #{expression}. Fix the Spec Bundle."
        end

        node = parsed.value.statements.body.last
        validate!(node)
        ->(context) { evaluate(node, context.transform_keys(&:to_sym)) }
      end

      private

      def validate!(node)
        node.compact_child_nodes.each { |child| validate!(child) }
        return unless node.type == :call_node && !CALLS.include?(node.name)

        raise ConfigurationError, "Contract method #{node.name} is not allowed. Use a supported first-order predicate."
      end

      def evaluate(node, context)
        case node.type
        when :local_variable_read_node then context.fetch(node.name)
        when :integer_node, :float_node then node.value
        when :string_node then node.unescaped
        when :symbol_node then node.unescaped.to_sym
        when :regular_expression_node then Regexp.new(node.unescaped)
        when :nil_node then nil
        when :true_node, :false_node then node.type == :true_node
        when :array_node then node.elements.map { |element| evaluate(element, context) }
        when :constant_read_node then CONSTANTS.fetch(node.name.to_s)
        when :and_node then evaluate(node.left, context) && evaluate(node.right, context)
        when :or_node then evaluate(node.left, context) || evaluate(node.right, context)
        when :parentheses_node then evaluate(node.body.body.last, context)
        when :call_node then evaluate_call(node, context)
        else raise ConfigurationError, "Contract syntax #{node.type} is not supported. Simplify the expression."
        end
      end

      def evaluate_call(node, context)
        receiver = evaluate(node.receiver, context)
        arguments = node.arguments&.arguments&.map { |argument| evaluate(argument, context) } || []
        receiver.public_send(node.name, *arguments)
      end
    end

    class ContractChecker
      def initialize(compiler: ContractCompiler.new)
        @compiler = compiler
      end

      def check(invariants, context)
        invariants.filter_map do |invariant|
          predicate = @compiler.compile(invariant.fetch("expr"))
          next if predicate.call(context)

          { "id" => invariant["id"], "expression" => invariant["expr"], "input" => context }
        rescue StandardError => e
          { "id" => invariant["id"], "expression" => invariant["expr"], "error" => e.message,
            "input" => context }
        end
      end
    end
  end
end
