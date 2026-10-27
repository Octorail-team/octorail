# frozen_string_literal: true

module Octorail
  class Compiler
    # A nested operation that leads back to one on the current path would recurse until
    # SystemStackError; this walks the nested graph (through wraps, branches and inherited steps).
    class NestedCycles
      def initialize(operation)
        @operation = operation
        @done = Set.new # operations already known to be cycle-free
      end

      def check! = walk(@operation, [@operation])

      private

      def walk(operation, path)
        operation.all_steps.grep(Nodes::Nested).each do |node|
          target = node.operation
          next if @done.include?(target)

          cycle!(path.drop(path.index(target)) << target, node) if path.include?(target)
          walk(target, path + [target])
        end
        @done << operation
      end

      def cycle!(cycle, node)
        raise CompileError, "#{@operation}: nested operations form a cycle: #{cycle.join(" → ")}" \
                            "#{Octorail.declared_at(node)}"
      end
    end
  end
end
