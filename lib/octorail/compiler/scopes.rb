# frozen_string_literal: true

module Octorail
  class Compiler
    # Where a failure leads from a list of nodes. Emitters ask the scope instead of hard-coding
    # `return`, so the same step code works at the top level, in a wrap, in a branch and around recovery.
    class Scope
      # trace_var: in the traced variant, the local holding the Trace::Node the nodes record into.
      attr_reader :nodes, :trace_var

      def initialize(nodes, compiler, trace_var: nil)
        @nodes = nodes
        @compiler = compiler
        @trace_var = trace_var
      end

      # Failure steps are positional: they handle failures of the nodes declared before them.
      def failure_steps_after(index)
        @nodes.drop(index + 1).select { |node| node.is_a?(Nodes::Step) && node.failure? }
      end

      # After the node at `index` failed: its failure steps (up to and including a fail_fast one, which
      # cuts the track), then the exit. The failed node's own fail_fast skips the failure track.
      # `error` / `step` are Ruby expressions (literals or locals).
      def emit_failure(code, index, error, step, fail_fast: false)
        return emit_exit(code, :fail_fast, error, step) if fail_fast

        failures = failure_steps_after(index)
        cut = failures.index(&:fail_fast)
        failures.take(cut ? cut + 1 : failures.size).each do |failure|
          @compiler.emit_failure_step(code, failure, error, step, self)
        end
        emit_exit(code, cut ? :fail_fast : :failure, error, step)
      end

      # Whether an exit leaves the list (return / next). False under recovery, where an exit only
      # records the outcome, so the nodes after it are guarded by the flag.
      def jumps? = true
    end

    # The operation's own nodes: exits return the Result.
    class TopScope < Scope
      def emit_exit(code, terminus, error, step)
        code.line("return #{@compiler.result}.new(#{terminus.inspect}, ctx, #{error}, #{step})")
      end
    end

    # Inside a wrap block `return` would skip the wrapper (and commit an ActiveRecord transaction),
    # so exits record the outcome in locals and leave the block with `next`.
    class WrapScope < Scope
      def initialize(nodes, compiler, id, trace_var: nil)
        super(nodes, compiler, trace_var:)
        @id = id
      end

      def var(name) = "__w#{@id}_#{name}"

      def emit_exit(code, terminus, error, step)
        code.line("#{var(:t)} = #{terminus.inspect}")
        code.line("#{var(:e)} = #{error}")
        code.line("#{var(:s)} = #{step}")
        code.line("next false")
      end
    end

    # A switch branch: no block around it, so a failure inside continues straight into the failure
    # track after the switch in the enclosing list (unless fail_fast cut it).
    class BranchScope < Scope
      def initialize(nodes, compiler, parent, index, trace_var: nil)
        super(nodes, compiler, trace_var:)
        @parent = parent
        @index = index
      end

      def emit_exit(code, terminus, error, step)
        return @parent.emit_exit(code, :fail_fast, error, step) if terminus == :fail_fast

        @parent.emit_failure(code, @index, error, step)
      end

      def jumps? = @parent.jumps?

      def var(name) = @parent.var(name)
    end

    # A list with a `failure ..., recover: true` step. The railway runs as a flat sequence over a
    # failure flag: a failure records terminus / error / step in locals; success nodes run only while
    # the flag is unset, failure steps only while it is :failure; a recovering step that returns truthy
    # clears it. At the end, a set flag leaves through the scope the list belongs to (`base`).
    class RecoveryScope < Scope
      attr_reader :base

      def initialize(base, compiler, id)
        super(base.nodes, compiler, trace_var: base.trace_var)
        @base = base
        @id = id
      end

      def var(name) = "__r#{@id}_#{name}"

      # Failure steps are separate statements here, run in order under the flag.
      def failure_steps_after(_index) = []

      def emit_exit(code, terminus, error, step)
        code.line("#{var(:t)} = #{terminus.inspect}")
        code.line("#{var(:e)} = #{error}")
        code.line("#{var(:s)} = #{step}")
      end

      def jumps? = false
    end
  end
end
