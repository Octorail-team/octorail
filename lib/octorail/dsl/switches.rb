# frozen_string_literal: true

module Octorail
  module DSL
    # switch / on: run one of several branches, picked by a decider method's result.
    module Switches
      def switch(decider, &block)
        check_not_abstract!("switch #{decider.inspect}")
        check_name!(decider, "switch")
        raise ArgumentError, "#{self}: switch #{decider.inspect} needs a block with on(...) branches" unless block

        location = declaration_location
        branches = collect_branches(decider, &block)
        raise ArgumentError, "#{self}: switch #{decider.inspect} has no on(...) branches" if branches.empty?

        current_nodes << Nodes::Switch.new(decider:, branches:, location:)
        invalidate!
        nil
      end

      # A branch without a block is an explicit "nothing to do for these keys".
      def on(*keys, &block)
        switch = @__octorail_switches&.last
        unless switch && @__octorail_nesting.size == switch[:depth]
          raise ArgumentError, "#{self}: on(...) is only allowed directly inside a switch block"
        end

        check_branch_keys!(switch, keys)
        switch[:branches] << Nodes::Branch.new(keys:, nodes: block ? collect_nodes(&block) : [])
        nil
      end

      private

      # Steps declared in the switch block but outside on(...) land in its own buffer: an error.
      def collect_branches(decider, &)
        switch = { decider:, branches: [], keys: [] }
        (@__octorail_switches ||= []).push(switch)
        stray = collect_nodes do
          switch[:depth] = @__octorail_nesting.size
          yield
        end
        return switch[:branches] if stray.empty?

        raise ArgumentError, "#{self}: switch #{decider.inspect}: steps must be inside on(...) branches"
      ensure
        @__octorail_switches.pop
      end

      def check_branch_keys!(switch, keys)
        label = "#{self}: switch #{switch[:decider].inspect}"
        raise ArgumentError, "#{label}: on needs at least one key" if keys.empty?
        raise ArgumentError, "#{label}: on #{keys.inspect} repeats a key" if keys.uniq.size < keys.size

        keys.each { |key| check_branch_key!(label, switch, key) }
        switch[:keys].concat(keys)
      end

      def check_branch_key!(label, switch, key)
        raise ArgumentError, "#{label}: on keys must be Symbols, got #{key.inspect}" unless key.is_a?(Symbol)
        raise ArgumentError, "#{label}: on #{key.inspect} is already a branch" if switch[:keys].include?(key)
      end

      # Steps of the finished branches of every switch being declared right now.
      def sibling_branch_steps
        branches = (@__octorail_switches || []).flat_map { |switch| switch[:branches] }
        Nodes.leaves(branches.flat_map(&:nodes))
      end
    end
  end
end
