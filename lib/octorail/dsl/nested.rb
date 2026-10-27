# frozen_string_literal: true

module Octorail
  module DSL
    # nested: run another operation as a step, on the same ctx.
    module Nested
      def nested(operation, error: nil, fail_fast: false)
        check_not_abstract!("nested #{operation}")
        check_nested!(operation, error, fail_fast)
        current_nodes << Nodes::Nested.new(operation:, error:, fail_fast:, location: declaration_location)
        invalidate!
        nil
      end

      private

      def check_nested!(operation, error, fail_fast)
        unless operation.is_a?(Class) && operation < Operation
          raise ArgumentError, "#{self}: nested: expected an Octorail::Operation subclass, got #{operation.inspect}"
        end

        check_not_recursive!(operation)
        unless error.nil? || error.is_a?(Symbol)
          raise ArgumentError, "#{self}: nested #{operation}: error: must be a Symbol, got #{error.inspect}"
        end
        return if [true, false].include?(fail_fast)

        raise ArgumentError, "#{self}: nested #{operation}: fail_fast: must be true or false, got #{fail_fast.inspect}"
      end

      # A subclass inherits this very nested step, so nesting it would recurse forever too.
      def check_not_recursive!(operation)
        return unless operation <= self

        what = operation.equal?(self) ? "itself" : "its own subclass"
        raise ArgumentError, "#{self}: nested #{operation}: an operation can't nest #{what}"
      end
    end
  end
end
