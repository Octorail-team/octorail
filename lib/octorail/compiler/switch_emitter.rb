# frozen_string_literal: true

module Octorail
  class Compiler
    # Emits a switch as a plain `case` over the decider's result.
    #
    #   case __s1 = flow_for(ctx, current_user: ctx.fetch(:current_user) { ... })
    #   when :admin
    #     unless grant_all(ctx)
    #       log_failure(ctx)
    #       return Result.new(:failure, ctx, :failure, :grant_all)
    #     end
    #   when :guest
    #   else
    #     __octorail_unknown_branch(0, __s1)
    #   end
    class SwitchEmitter
      def initialize(compiler)
        @compiler = compiler
      end

      def emit(code, switch, index, scope)
        id = @compiler.next_id
        value = "__s#{id}"
        trace = @compiler.start_trace(code, scope, :switch, switch.decider, id)
        decide = @compiler.signature(switch, branches: false).expression
        code.line("case #{value} = #{trace ? "#{trace}.taken(#{decide})" : decide}")
        emit_branches(code, switch, index, scope, trace)
        emit_unknown(code, switch, value)
        @compiler.done_trace(code, scope, trace, "true")
      end

      private

      def emit_branches(code, switch, index, scope, trace)
        switch.branches.each do |branch|
          code.line("when #{branch.keys.map(&:inspect).join(", ")}")
          branch_scope = BranchScope.new(branch.nodes, @compiler, scope, index, trace_var: trace)
          code.indented { @compiler.emit_nodes(code, branch_scope) }
        end
      end

      def emit_unknown(code, switch, value)
        code.line("else")
        code.indented do
          code.line("__octorail_unknown_branch(#{@compiler.method_index(switch)}, #{value})")
        end
        code.line("end")
      end
    end
  end
end
