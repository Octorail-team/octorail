# frozen_string_literal: true

module Octorail
  class Compiler
    # Emits a wrap: the wrapper call with the inner nodes compiled into its block.
    #
    #   __w1_t = __w1_e = __w1_s = nil
    #   __w1_ok = ::Transaction.call(ctx) do
    #     __w1_t = __w1_e = __w1_s = nil
    #     unless charge(ctx)
    #       __w1_t = :failure; __w1_e = :failure; __w1_s = :charge
    #       next false
    #     end
    #     true
    #   end
    #   unless __w1_ok
    #     ...outer failure steps...
    #     return Result.new(:failure, ctx, __w1_t ? __w1_e : :failure, __w1_t ? __w1_s : nil)
    #   end
    class WrapEmitter
      def initialize(compiler)
        @compiler = compiler
      end

      def emit(code, wrap, index, scope)
        id = @compiler.next_id
        trace = @compiler.start_trace(code, scope, :wrap, @compiler.trace_label(wrap.wrapper), id)
        inner = WrapScope.new(wrap.nodes, @compiler, id, trace_var: trace)
        emit_block(code, wrap, inner)
        @compiler.done_trace(code, scope, trace, inner.var(:ok))
        emit_failure(code, wrap, index, inner, scope)
      end

      private

      def emit_block(code, wrap, inner)
        reset = "#{inner.var(:t)} = #{inner.var(:e)} = #{inner.var(:s)} = nil"
        code.line(reset)
        code.block("#{inner.var(:ok)} = #{wrapper_call(wrap)} do") do
          code.line(reset) # again inside: a wrapper may yield more than once (retries)
          @compiler.emit_nodes(code, inner)
          code.line("true")
        end
      end

      # The wrap failed: a step inside failed (its outcome is in the locals) or the wrapper itself
      # returned falsy (no locals set, so the wrap's own error / name apply).
      # A fail_fast inside keeps its meaning outside: the outer failure steps are skipped too.
      def emit_failure(code, wrap, index, inner, scope)
        error, step = outcome(wrap, inner)
        code.block("unless #{inner.var(:ok)}") do
          next scope.emit_failure(code, index, error, step) unless wrap.steps.any?(&:fail_fast)

          code.if_else("#{inner.var(:t)} == :fail_fast", -> { scope.emit_exit(code, :fail_fast, error, step) },
                       -> { scope.emit_failure(code, index, error, step) })
        end
      end

      # error / failed_step expressions: what the exit inside recorded (even nil), else the wrap's own.
      def outcome(wrap, inner)
        exited = inner.var(:t)
        ["#{exited} ? #{inner.var(:e)} : #{(wrap.error || :failure).inspect}",
         "#{exited} ? #{inner.var(:s)} : #{wrap.name.inspect}"]
      end

      def wrapper_call(wrap)
        wrapper = wrap.wrapper
        return @compiler.signature(wrap, branches: false).expression if wrapper.is_a?(Symbol)

        "#{@compiler.constant_for(wrapper)}.call(ctx)"
      end
    end
  end
end
