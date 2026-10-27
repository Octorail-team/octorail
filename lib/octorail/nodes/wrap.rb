# frozen_string_literal: true

module Octorail
  module Nodes
    # A group of nodes run inside `wrapper`: an operation method name (Symbol) or an object
    # responding to `.call(ctx) { }`. The wrapper yields to run the nodes (the block returns
    # true/false) and its own return value decides whether the wrap succeeded.
    Wrap = Data.define(:wrapper, :nodes, :error, :location)

    class Wrap
      def initialize(wrapper:, nodes:, error: nil, location: nil)
        super
      end

      # Used as failed_step when the wrapper itself fails without a step failing inside.
      def name = wrapper.is_a?(Symbol) ? wrapper : nil

      def type = :wrap

      def children = nodes

      # Steps and nested operations inside, at any depth, in declaration order.
      def steps = Nodes.leaves(nodes)
    end
  end
end
