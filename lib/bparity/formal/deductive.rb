# frozen_string_literal: true

require "open3"
require "prism"
require "timeout"

module Bparity
  module Formal
    module Deductive
      class Term
        attr_reader :smt, :sort

        def initialize(smt, sort, &evaluator)
          @smt = smt
          @sort = sort
          @evaluator = evaluator
        end

        def evaluate(context) = @evaluator.call(context)
      end

      Translation = Struct.new(:parameters, :term, :source, :method_name, keyword_init: true)

      class FragmentChecker
        FORBIDDEN_NODES = %i[class_variable_write_node global_variable_write_node instance_variable_write_node
                             call_and_write_node call_operator_write_node].freeze
        FORBIDDEN_CALLS = %i[eval binding send public_send method_missing define_method rand sleep].freeze

        def check_file(path, method_name)
          result = Prism.parse_file(path)
          return ["syntax error"] unless result.success?

          method = nodes(result.value).find { |node| node.type == :def_node && node.name.to_s == method_name.to_s }
          return ["method #{method_name} was not found"] unless method

          nodes(method).filter_map do |node|
            if FORBIDDEN_NODES.include?(node.type)
              "#{node.type} at line #{node.location.start_line}"
            elsif node.type == :call_node && FORBIDDEN_CALLS.include?(node.name)
              "#{node.name} at line #{node.location.start_line}"
            end
          end
        end

        private

        def nodes(root, &)
          return enum_for(__method__, root) unless block_given?

          yield root
          root.compact_child_nodes.each { |child| nodes(child, &) }
        end
      end

      class RubyToSmt
        SORTS = { "Integer" => "Int", "Boolean" => "Bool", "String" => "String" }.freeze
        OPERATORS = { :+ => "+", :- => "-", :* => "*", :== => "=", :!= => "distinct",
                      :> => ">", :>= => ">=", :< => "<", :<= => "<=" }.freeze

        def translate_file(path, method_name, parameter_types:)
          result = Prism.parse_file(path)
          raise ConfigurationError, "Cannot parse #{path}. Fix its Ruby syntax." unless result.success?

          method = find_method(result.value, method_name)
          raise ConfigurationError, "Method #{method_name} was not found in #{path}." unless method

          parameters = method.parameters.requireds.map(&:name)
          if parameters.length != parameter_types.length
            message = "Method #{method_name} has #{parameters.length} parameters, " \
                      "but #{parameter_types.length} types were given."
            raise ConfigurationError,
                  message
          end

          environment = parameters.each_with_index.to_h do |name, index|
            sort = SORTS.fetch(parameter_types[index]) do
              raise ConfigurationError,
                    "F4 does not support #{parameter_types[index]}. Use Integer, Boolean, or String."
            end
            [name, Term.new("arg#{index}", sort) { |context| context.fetch(index) }]
          end
          body = translate_statements(method.body, environment)
          Translation.new(parameters: parameter_types.each_with_index.map do |type, index|
            ["arg#{index}", SORTS.fetch(type)]
          end,
                          term: body, source: path, method_name: method_name.to_s)
        end

        private

        def find_method(root, name)
          return root if root.type == :def_node && root.name.to_s == name.to_s

          root.compact_child_nodes.filter_map { |child| find_method(child, name) }.first
        end

        def translate_statements(node, environment)
          statements = node.type == :statements_node ? node.body : [node]
          final = nil
          statements.each do |statement|
            if statement.type == :local_variable_write_node
              environment[statement.name] = translate(statement.value, environment)
            else
              final = translate(statement, environment)
            end
          end
          final || Term.new("true", "Bool") { true }
        end

        def translate(node, environment)
          case node.type
          when :local_variable_read_node then environment.fetch(node.name)
          when :integer_node then literal(node.value, "Int")
          when :string_node then string_literal(node.unescaped)
          when :true_node, :false_node then literal(node.type == :true_node, "Bool")
          when :parentheses_node then translate_statements(node.body, environment.dup)
          when :if_node then translate_if(node, environment)
          when :return_node then translate(node.arguments.arguments.first, environment)
          when :call_node then translate_call(node, environment)
          else unsupported!(node)
          end
        end

        def translate_if(node, environment)
          unsupported!(node) unless node.subsequent

          condition = translate(node.predicate, environment)
          truthy = translate_statements(node.statements, environment.dup)
          falsy = translate_else(node.subsequent, environment.dup)
          ensure_sort!(truthy, falsy, node)
          Term.new("(ite #{condition.smt} #{truthy.smt} #{falsy.smt})", truthy.sort) do |context|
            condition.evaluate(context) ? truthy.evaluate(context) : falsy.evaluate(context)
          end
        end

        def translate_else(node, environment)
          return translate_if(node, environment) if node.type == :if_node

          translate_statements(node.statements, environment)
        end

        def translate_call(node, environment)
          receiver = translate(node.receiver, environment)
          arguments = node.arguments&.arguments&.map { |argument| translate(argument, environment) } || []
          return translate_string_call(node.name, receiver, arguments, node) if receiver.sort == "String"
          return translate_operator(node.name, receiver, arguments.first, node) if OPERATORS.key?(node.name)

          unsupported!(node)
        end

        def translate_operator(name, left, right, node)
          ensure_sort!(left, right, node)
          output_sort = %i[== != > >= < <=].include?(name) ? "Bool" : left.sort
          Term.new("(#{OPERATORS.fetch(name)} #{left.smt} #{right.smt})", output_sort) do |context|
            left.evaluate(context).public_send(name, right.evaluate(context))
          end
        end

        def translate_string_call(name, receiver, arguments, node)
          case name
          when :+
            argument = arguments.fetch(0)
            ensure_sort!(receiver, argument, node)
            Term.new("(str.++ #{receiver.smt} #{argument.smt})", "String") do |context|
              receiver.evaluate(context) + argument.evaluate(context)
            end
          when :size, :length
            Term.new("(str.len #{receiver.smt})", "Int") { |context| receiver.evaluate(context).length }
          when :empty?
            Term.new("(= #{receiver.smt} \"\")", "Bool") { |context| receiver.evaluate(context).empty? }
          when :start_with?, :end_with?, :include?
            string_predicate(name, receiver, arguments.fetch(0))
          else unsupported!(node)
          end
        end

        def string_predicate(name, receiver, argument)
          smt_name = { start_with?: "str.prefixof", end_with?: "str.suffixof", include?: "str.contains" }.fetch(name)
          smt_args = name == :include? ? [receiver, argument] : [argument, receiver]
          Term.new("(#{smt_name} #{smt_args.map(&:smt).join(' ')})", "Bool") do |context|
            receiver.evaluate(context).public_send(name, argument.evaluate(context))
          end
        end

        def literal(value, sort)
          smt = case value
                when true then "true"
                when false then "false"
                else value.to_s
                end
          Term.new(smt, sort) { value }
        end

        def string_literal(value)
          escaped = value.gsub('"', '""')
          Term.new(%("#{escaped}"), "String") { value }
        end

        def ensure_sort!(left, right, node)
          return if left.sort == right.sort

          raise ConfigurationError,
                "F4 sort mismatch at line #{node.location.start_line}. Add compatible parameter types."
        end

        def unsupported!(node)
          message = "F4 does not support #{node.type} at line #{node.location.start_line}. " \
                    "Use F2 or simplify the pure fragment."
          raise ConfigurationError,
                message
        end
      end

      module ProductProgram
        module_function

        def call(old_translation, new_translation)
          unless old_translation.parameters == new_translation.parameters &&
                 old_translation.term.sort == new_translation.term.sort
            raise ConfigurationError, "The F4 translations have incompatible input or output sorts."
          end

          logic = if old_translation.term.sort == "String" || old_translation.parameters.any? do |_name, sort|
            sort == "String"
          end
                    "ALL"
                  else
                    "QF_LIA"
                  end
          declarations = old_translation.parameters.map { |name, sort| "(declare-const #{name} #{sort})" }
          (["(set-logic #{logic})"] + declarations +
            ["(assert (not (= #{old_translation.term.smt} #{new_translation.term.smt})))", "(check-sat)",
             "(get-model)"]).join("\n") << "\n"
        end
      end

      Validation = Struct.new(:valid, :cases, :mismatch, keyword_init: true)

      class TranslationValidator
        def validate(translation, callable, inputs)
          inputs.each_with_index do |input, index|
            ruby_value = observe { callable.call(*input) }
            context = input.each_with_index.to_h { |value, position| [position, value] }
            translated_value = observe { translation.term.evaluate(context) }
            next if ruby_value == translated_value

            mismatch = { "input" => input, "ruby" => ruby_value, "translation" => translated_value }
            return Validation.new(valid: false, cases: index + 1, mismatch:)
          end
          Validation.new(valid: true, cases: inputs.length)
        end

        private

        def observe
          { "kind" => "return", "value" => yield }
        rescue StandardError => e
          { "kind" => "raise", "class" => e.class.name, "message" => e.message }
        end
      end

      class Z3
        def initialize(timeout: 300)
          @timeout = timeout
        end

        def available?
          _out, _err, status = Open3.capture3("z3", "--version")
          status.success?
        rescue Errno::ENOENT
          false
        end

        def solve(script)
          output = error = status = nil
          Open3.popen3("z3", "-in") do |stdin, stdout, stderr, wait|
            stdin.write(script)
            stdin.close
            Timeout.timeout(@timeout) do
              output = stdout.read
              error = stderr.read
              status = wait.value
            end
          rescue Timeout::Error
            Process.kill("TERM", wait.pid) unless wait.join(0.1)
            return { verdict: :unknown, output: "z3 timed out after #{@timeout} seconds" }
          end
          return { verdict: :unknown, output: error } unless status.success?

          first = output.lines.first&.strip
          { verdict: { "unsat" => :unsat, "sat" => :sat }.fetch(first, :unknown), output: output }
        rescue Errno::ENOENT
          { verdict: :unavailable, output: "z3 executable not found" }
        end
      end

      class Runner
        def initialize(old_translation:, new_translation:, old_callable:, new_callable:, validation_inputs:,
                       assumptions: %i[h1 h3], solver: Z3.new)
          @old_translation = old_translation
          @new_translation = new_translation
          @old_callable = old_callable
          @new_callable = new_callable
          @validation_inputs = validation_inputs
          @assumptions = assumptions
          @solver = solver
        end

        def run
          validations = validate_translations
          return result(:inconclusive, validations, "translation validation failed") unless validations.all?(&:valid)
          return result(:inconclusive, validations, "z3 executable not found") unless @solver.available?

          solved = @solver.solve(ProductProgram.call(@old_translation, @new_translation))
          case solved[:verdict]
          when :unsat then result(:no_difference_found, validations, "Z3 returned unsat")
          when :sat then result(:difference_found, validations, "Z3 returned sat", solved[:output])
          else result(:inconclusive, validations, "Z3 returned unknown", solved[:output])
          end
        end

        private

        def validate_translations
          validator = TranslationValidator.new
          [validator.validate(@old_translation, @old_callable, @validation_inputs),
           validator.validate(@new_translation, @new_callable, @validation_inputs)]
        end

        def result(verdict, validations, reason, counterexample = nil)
          cases = validations.map(&:cases).min
          Result.new(level: :f4, verdict:,
                     scope: Scope.new(size: "unbounded", depth: nil, cases:, exhaustive: verdict != :inconclusive),
                     assumptions: @assumptions,
                     out_of_scope: ["Ruby outside the declared pure fragment", "unsupported library semantics"],
                     counterexample: counterexample && { "solver_model" => counterexample },
                     details: { "reason" => reason, "translation_validation" => validations.map(&:to_h) })
        end
      end
    end
  end
end
