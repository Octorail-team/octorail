# frozen_string_literal: true

module Octorail
  module Nodes
    # A fork: `decider` is the instance method whose result (a Symbol) picks the branch to run.
    Switch = Data.define(:decider, :branches, :location)

    class Switch
      def initialize(decider:, branches:, location: nil)
        super
      end

      def name = decider

      def type = :switch

      def children = branches.flat_map(&:nodes)

      def keys = branches.flat_map(&:keys)
    end

    # One `on(:a, :b) { ... }` of a switch.
    Branch = Data.define(:keys, :nodes)
  end
end
