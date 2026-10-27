# frozen_string_literal: true

module Octorail
  module DSL
    # wrap: run a group of steps inside a wrapper (transaction, lock, timeout, ...).
    module Wraps
      def wrap(wrapper, error: nil, &block)
        check_not_abstract!("wrap #{wrapper.inspect}")
        check_wrap!(wrapper, error, block)
        location = declaration_location
        nodes = collect_nodes(&block)
        raise ArgumentError, "#{self}: wrap #{wrapper.inspect} has no steps" if nodes.empty?

        current_nodes << Nodes::Wrap.new(wrapper:, nodes:, error:, location:)
        invalidate!
        nil
      end

      private

      def check_wrap!(wrapper, error, block)
        check_wrapper!(wrapper)
        raise ArgumentError, "#{self}: wrap #{wrapper.inspect} needs a block with steps" unless block
        return if error.nil? || error.is_a?(Symbol)

        raise ArgumentError, "#{self}: wrap #{wrapper.inspect}: error: must be a Symbol, got #{error.inspect}"
      end

      def check_wrapper!(wrapper)
        return check_name!(wrapper, "wrap") if wrapper.is_a?(Symbol)
        if wrapper.is_a?(Class) && wrapper < Operation
          raise ArgumentError, "#{self}: wrap #{wrapper}: is an operation; to run it as a step use nested #{wrapper}"
        end
        return if wrapper.respond_to?(:call)

        raise ArgumentError, "#{self}: wrap: wrapper must be a method name (Symbol) or respond to .call, " \
                             "got #{wrapper.inspect}"
      end

      # Steps declared inside a wrap block go into a buffer instead of the class's own list.
      def collect_nodes
        (@__octorail_nesting ||= []).push([])
        yield
        @__octorail_nesting.last
      ensure
        @__octorail_nesting.pop
      end
    end
  end
end
