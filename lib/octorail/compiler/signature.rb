# frozen_string_literal: true

module Octorail
  class Compiler
    # Reads a step method's parameters and emits the Ruby code that calls it.
    class Signature
      # Up to this many optional kwargs compile to `ctx.key?` branches; more use `ctx.slice`.
      MAX_OPTIONAL_BRANCHES = 2
      NON_POSITIONAL = %i[key keyreq keyrest nokey block].freeze
      # Keywords a failure step may take that come from the failure itself, not from ctx.
      BOUND = %i[error failed_step].freeze

      def initialize(operation, step, index, branches: true)
        @operation = operation
        @step = step
        @index = index
        @branches = branches
        @required = []
        @optional = []
        @bound = []
        parse(operation.instance_method(step.name).parameters)
      end

      # False when optional kwargs need an if/else tree of `ctx.key?` checks.
      def single_line?
        @optional.empty? || !@branches || @optional.size > MAX_OPTIONAL_BRANCHES
      end

      # `bindings`: Ruby expressions for the bound keywords (error:, failed_step:) of a failure step.
      def expression(**bindings)
        @optional.empty? ? call_with([], bindings) : sliced_call(bindings)
      end

      def emit(code, **bindings)
        single_line? ? code.line(expression(**bindings)) : emit_branches(code, [], @optional, bindings)
      end

      private

      def parse(parameters)
        check_positional!(parameters)
        parameters.each do |type, name|
          next @bound << name if bound?(type, name)

          check_not_bound!(type, name)

          case type
          when :keyreq then @required << name
          when :key then @optional << name
          when :keyrest then error!("uses ** in its signature; declare the keys it needs as keyword arguments")
          end
        end
      end

      def bound?(type, name)
        %i[keyreq key].include?(type) && BOUND.include?(name) && @step.is_a?(Nodes::Step) && @step.failure?
      end

      # Read from ctx these would be reserved keys (Result::RESERVED_CTX_KEYS): the step could never run.
      def check_not_bound!(type, name)
        return unless %i[keyreq key].include?(type) && BOUND.include?(name)

        error!("takes #{name}:, which only failure steps get (it's a reserved key, never in ctx)")
      end

      def check_positional!(parameters)
        positional = parameters.map(&:first) - NON_POSITIONAL
        return if positional == [:req]

        error!("must take ctx as its only positional argument: def #{@step.name}(ctx, ...)")
      end

      # Pass each optional key only when ctx has it, so the method default applies otherwise.
      def emit_branches(code, present, rest, bindings)
        return code.line(call_with(present, bindings)) if rest.empty?

        key, *tail = rest
        code.if_else(
          "ctx.key?(#{key.inspect})",
          -> { emit_branches(code, present + [key], tail, bindings) },
          -> { emit_branches(code, present, tail, bindings) }
        )
      end

      def call_with(optional, bindings)
        render(base_args(bindings) + optional.map { |key| "#{key}: ctx[#{key.inspect}]" })
      end

      # ctx.slice keeps only present keys, so absent ones fall back to the method defaults.
      def sliced_call(bindings)
        render(base_args(bindings) + ["**ctx.slice(#{@optional.map(&:inspect).join(", ")})"])
      end

      def base_args(bindings)
        required = @required.map do |key|
          missing = "__octorail_missing_key(#{@index}, #{key.inspect}, ctx, #{@step.name.inspect})"
          "#{key}: ctx.fetch(#{key.inspect}) { #{missing} }"
        end
        ["ctx", *required, *@bound.map { |key| "#{key}: #{bindings.fetch(key)}" }]
      end

      def render(args)
        "#{@step.name}(#{args.join(", ")})"
      end

      def error!(message)
        raise CompileError, "#{@operation}: #{@step.type} #{@step.name.inspect} #{message}" \
                            "#{Octorail.declared_at(@step)}"
      end
    end
  end
end
