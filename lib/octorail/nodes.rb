# frozen_string_literal: true

require_relative "nodes/step"
require_relative "nodes/wrap"
require_relative "nodes/nested"
require_relative "nodes/switch"

module Octorail
  # What the DSL records and the compiler reads. Wrap and Switch hold other nodes (`children`).
  module Nodes
    # Every node in `nodes` and inside them, depth-first, in declaration order.
    def self.walk(nodes)
      nodes.flat_map { |node| [node, *walk(node.children)] }
    end

    # Nodes that run something themselves (a step method or a nested operation), not containers.
    def self.leaves(nodes)
      walk(nodes).select { |node| node.is_a?(Step) || node.is_a?(Nested) }
    end
  end
end
