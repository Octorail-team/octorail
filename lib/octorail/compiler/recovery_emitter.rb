# frozen_string_literal: true

module Octorail
  class Compiler
    # Emits a list that has a `failure ..., recover: true` step (see RecoveryScope):
    #
    #   __r1_t = __r1_e = __r1_s = nil
    #   unless charge_card(ctx)
    #     __r1_t = :failure; __r1_e = :declined; __r1_s = :charge_card
    #   end
    #   if __r1_t == :failure
    #     if charge_wallet(ctx, failed_step: __r1_s)
    #       __r1_t = nil
    #     end
    #   end
    #   unless __r1_t
    #     ...next steps...
    #   end
    #   if __r1_t
    #     ...leave through the list's own scope (return / next / outer failure track)...
    #   end
    class RecoveryEmitter
      def self.needed?(nodes) = nodes.any? { |node| node.is_a?(Nodes::Step) && node.recover }

      def initialize(compiler)
        @compiler = compiler
      end

      def emit(code, base)
        scope = RecoveryScope.new(base, @compiler, @compiler.next_id)
        flag = scope.var(:t)
        code.line("#{flag} = #{scope.var(:e)} = #{scope.var(:s)} = nil")
        base.nodes.each_with_index do |node, index|
          next emit_failure_step(code, scope, node) if @compiler.failure_step?(node)

          @compiler.emit_node(code, node, index, scope, unless_flag: flag)
        end
        emit_exit(code, scope)
      end

      private

      # Runs only on the failure track; a recovering one that returns truthy clears the flag;
      # a fail_fast one (that didn't recover) cuts the track.
      def emit_failure_step(code, scope, failure)
        flag = scope.var(:t)
        code.block("if #{flag} == :failure") do
          next emit_plain(code, scope, failure) unless failure.recover

          recovered = @compiler.condition(code, failure, scope, type: :recover,
                                                                error: scope.var(:e), failed_step: scope.var(:s))
          next code.block("if #{recovered}") { code.line("#{flag} = nil") } unless failure.fail_fast

          code.if_else(recovered, -> { code.line("#{flag} = nil") }, -> { code.line("#{flag} = :fail_fast") })
        end
      end

      def emit_plain(code, scope, failure)
        @compiler.emit_failure_step(code, failure, scope.var(:e), scope.var(:s), scope)
        code.line("#{scope.var(:t)} = :fail_fast") if failure.fail_fast
      end

      def emit_exit(code, scope)
        flag = scope.var(:t)
        exit = ->(terminus) { -> { scope.base.emit_exit(code, terminus, scope.var(:e), scope.var(:s)) } }
        code.block("if #{flag}") { code.if_else("#{flag} == :fail_fast", exit.call(:fail_fast), exit.call(:failure)) }
      end
    end
  end
end
