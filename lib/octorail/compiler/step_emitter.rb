# frozen_string_literal: true

module Octorail
  class Compiler
    # Emits step / pass nodes. :failure steps are emitted inside the failure branches of the steps
    # before them (see Scope#emit_failure), or as guarded statements under recovery.
    class StepEmitter
      def initialize(compiler)
        @compiler = compiler
      end

      def emit(code, step, index, scope)
        case step.type
        when :step then emit_railway(code, step, index, scope)
        when :pass then emit_pass(code, step, scope)
        end
      end

      private

      def emit_pass(code, step, scope)
        return @compiler.signature(step).emit(code) unless @compiler.traced?

        @compiler.emit_call(code, step, scope)
      end

      def emit_railway(code, step, index, scope)
        error = (step.error || :failure).inspect
        code.block("unless #{@compiler.condition(code, step, scope)}") do
          scope.emit_failure(code, index, error, step.name.inspect, fail_fast: step.fail_fast)
        end
      end
    end
  end
end
