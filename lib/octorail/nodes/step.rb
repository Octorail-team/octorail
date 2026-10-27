# frozen_string_literal: true

module Octorail
  module Nodes
    # A declared step. `type` is :step, :pass or :failure; `name` is the instance method to call;
    # `recover` (failure only): a truthy result returns to the success track;
    # `location` is where it was declared ("path:line"), for error messages.
    Step = Data.define(:type, :name, :error, :fail_fast, :recover, :location)

    class Step
      def initialize(type:, name:, error: nil, fail_fast: false, recover: false, location: nil) # rubocop:disable Metrics/ParameterLists
        super
      end

      def children = []

      def failure? = type == :failure
    end
  end
end
