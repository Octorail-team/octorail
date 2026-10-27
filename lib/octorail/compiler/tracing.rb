# frozen_string_literal: true

module Octorail
  class Compiler
    # Calls of step methods, plain or traced. In the traced variant every call is wrapped into
    # `trace.run(type, name) { call }`, which records the node (and a raise) and passes the result
    # through; `trace` is the Ruby expression for the current container node (Scope#trace_var).
    module Tracing
      def traced? = @traced

      # A one-line call goes straight into the condition; an if/else tree is assigned to `ok` first.
      def condition(code, node, scope, type: node.type, **bindings)
        sig = signature(node)
        trace = scope.trace_var
        run = "#{trace}.run(#{type.inspect}, #{node.name.inspect})" if trace
        return multiline_condition(code, sig, run, bindings) unless sig.single_line?

        call = sig.expression(**bindings)
        run ? "#{run} { #{call} }" : call
      end

      def multiline_condition(code, sig, run, bindings)
        code.line(run ? "ok = #{run} do" : "ok =")
        code.indented { sig.emit(code, **bindings) }
        code.line("end") if run
        "ok"
      end

      # A call whose result is not used (pass, failure step).
      def emit_call(code, node, scope, type: node.type, **bindings)
        call = condition(code, node, scope, type:, **bindings)
        code.line(call) unless call == "ok"
      end

      # `__tw1 = __t.start(:wrap, "Transaction")` before a container node; returns the new local.
      def start_trace(code, scope, type, name, id)
        return unless traced?

        var = "__t#{type.to_s[0]}#{id}"
        code.line("#{var} = #{scope.trace_var}.start(#{type.inspect}, #{name.inspect})")
        var
      end

      def done_trace(code, scope, var, value)
        code.line("#{scope.trace_var}.done(#{var}, #{value})") if var
      end

      # What a trace shows for a wrapper or a nested operation.
      def trace_label(object)
        return object.to_s if object.is_a?(Symbol)

        (object.is_a?(Module) && object.name) || object.inspect
      end
    end
  end
end
