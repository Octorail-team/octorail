# frozen_string_literal: true

module Octorail
  module Nodes
    # Another operation run as a step on the same ctx (`nested Billing::Charge`).
    Nested = Data.define(:operation, :error, :fail_fast, :location)

    class Nested
      def initialize(operation:, error: nil, fail_fast: false, location: nil)
        super
      end

      def type = :nested

      def children = []
    end
  end
end
