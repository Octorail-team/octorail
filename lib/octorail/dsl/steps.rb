# frozen_string_literal: true

module Octorail
  module DSL
    # step / pass / failure.
    module Steps
      OPTIONS = {
        step: %i[error fail_fast],
        pass: [],
        failure: %i[fail_fast recover]
      }.freeze
      FLAGS = %i[fail_fast recover].freeze
      BOOLEANS = [true, false].freeze

      def step(name, **options) = add_step(:step, name, options)
      def pass(name, **options) = add_step(:pass, name, options)
      def failure(name, **options) = add_step(:failure, name, options)

      # Top-level nodes (steps, wraps, nested, switches) in execution order: inherited ones first, then own.
      def steps
        parent = superclass.respond_to?(:steps) ? superclass.steps : []
        parent + own_steps
      end

      # Every step and nested operation, including the ones inside wraps and branches, in declaration order.
      def all_steps = Nodes.leaves(steps)

      # Nodes whose instance method the compiled code calls: steps, Symbol wrappers, switch deciders.
      def method_nodes
        Nodes.walk(steps).select do |node|
          node.is_a?(Nodes::Step) || node.is_a?(Nodes::Switch) || (node.is_a?(Nodes::Wrap) && node.name)
        end
      end

      def step_method_names = method_nodes.map(&:name)

      private

      def own_steps = @own_steps ||= []

      # Where a step declared right now goes: the innermost open wrap block, or the class itself.
      def current_nodes
        @__octorail_nesting&.last || own_steps
      end

      # Steps of this class's whole line: ancestors, itself (with open wrap / branch blocks) and
      # descendants, so that reopening a parent can't duplicate a step a subclass already has.
      # Steps in other branches of a switch being declared are left out: branches never both run.
      def related_steps
        pending = (@__octorail_nesting || []).flatten
        nodes = steps + pending + descendants.flat_map { |subclass| subclass.__send__(:own_steps) }
        siblings = sibling_branch_steps
        Nodes.leaves(nodes).grep(Nodes::Step).reject { |node| siblings.any? { |sibling| sibling.equal?(node) } }
      end

      def add_step(type, name, options)
        check_not_abstract!("#{type} #{name.inspect}")
        check_name!(name, type)
        check_options!(type, name, options)
        check_duplicate_step!(type, name)

        current_nodes << Nodes::Step.new(type:, name:, location: declaration_location, **options)
        invalidate!
        nil
      end

      def check_duplicate_step!(type, name)
        original = related_steps.find { |node| node.name == name }
        if original
          raise ArgumentError, "#{self}: #{type} #{name.inspect} is already declared " \
                               "(#{original.type} #{name.inspect})#{Octorail.declared_at(original)}"
        end

        check_sibling_type!(type, name)
      end

      # A method reused in another branch keeps its type: a failure step's `error:` / `failed_step:`
      # come from the failure, a step's from ctx, and one compiled method can't be both.
      def check_sibling_type!(type, name)
        sibling = sibling_branch_steps.find { |node| node.is_a?(Nodes::Step) && node.name == name }
        return if sibling.nil? || sibling.type == type

        raise ArgumentError, "#{self}: #{type} #{name.inspect} is #{sibling.type} #{name.inspect} in another " \
                             "branch; a step reused across branches keeps its type#{Octorail.declared_at(sibling)}"
      end

      def check_options!(type, name, options)
        label = "#{self}: #{type} #{name.inspect}"
        allowed = OPTIONS.fetch(type)
        unknown = options.keys - allowed
        raise ArgumentError, "#{label}: unknown options #{unknown.inspect}, allowed: #{allowed.inspect}" if unknown.any?

        check_option_values!(label, options)
      end

      def check_option_values!(label, options)
        error = options[:error]
        unless error.nil? || error.is_a?(Symbol)
          raise ArgumentError, "#{label}: error: must be a Symbol, got #{error.inspect}"
        end

        FLAGS.each do |flag|
          value = options.fetch(flag, false)
          next if BOOLEANS.include?(value)

          raise ArgumentError, "#{label}: #{flag}: must be true or false, got #{value.inspect}"
        end
      end
    end
  end
end
