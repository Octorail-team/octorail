# frozen_string_literal: true

module Octorail
  class Compiler
    # Emits a nested operation: called with the same ctx, its Result decides like a step's return value.
    #
    #   __n1 = ::Billing::Charge.nested_call(ctx)
    #   unless __n1.success?
    #     log_failure(ctx)
    #     return Result.new(:failure, ctx, __n1.error, __n1.failed_step)
    #   end
    #
    # The inner error / failed_step show through (error: replaces the error); the inner terminus
    # doesn't: only the node's own fail_fast skips the outer failure steps.
    class NestedEmitter
      def initialize(compiler)
        @compiler = compiler
      end

      def emit(code, nested, index, scope)
        id = @compiler.next_id
        result = "__n#{id}"
        trace = @compiler.start_trace(code, scope, :nested, @compiler.trace_label(nested.operation), id)
        code.line("#{result} = #{@compiler.constant_for(nested.operation)}.nested_call(ctx#{", #{trace}" if trace})")
        @compiler.done_trace(code, scope, trace, "#{result}.success?")
        error = nested.error ? nested.error.inspect : "#{result}.error"
        code.block("unless #{result}.success?") do
          scope.emit_failure(code, index, error, "#{result}.failed_step", fail_fast: nested.fail_fast)
        end
      end
    end
  end
end
