# frozen_string_literal: true

module Octorail
  # The path one traced call took through an operation (docs/tracing.md). Built by the traced
  # variant of the generated code: every step, wrap, switch and nested operation becomes a Node.
  # Holds names, outcomes, branch keys and durations only, never ctx values.
  class Trace
    LEVELS = %i[off path profile].freeze

    # One traced node. Containers (wrap, switch, nested, the operation itself) hold child nodes.
    class Node
      NONE = [].freeze
      private_constant :NONE

      # `value`: true / false only, what the node returned taken as a condition (never the object
      # itself: it may hold ctx data, and must not stop the exception carrying the trace from
      # being serialized). `exception`: what a step raised. `inner`: the trace of a separate
      # traced operation that step called, carried in by the exception.
      attr_reader :type, :name, :value, :branch, :duration, :exception, :inner

      def initialize(type, name, profile)
        @type = type
        @name = name
        @profile = profile
        @started = Process.clock_gettime(Process::CLOCK_MONOTONIC) if profile
      end

      # Generated code for a step call: `trace.run(:step, :charge) { charge(ctx) }`.
      # A raise is recorded on the step's own node, even if a wrapper rescues it later.
      def run(type, name)
        node = start(type, name)
        value = yield
        node.close(value)
        value
      rescue ::Exception => e # rubocop:disable Lint/RescueException
        node&.raised(e)
        raise
      end

      # Generated code for a container: `__tw1 = trace.start(:wrap, "Transaction")`, then `done`.
      def start(type, name)
        node = Node.new(type, name, @profile)
        (@children ||= []) << node
        node
      end

      # Only containers get an array: steps are leaves.
      def children = @children || NONE

      # Records what the node returned and passes it through unchanged.
      def done(node, value)
        node.close(value)
        value
      end

      # The switch decider's result: recorded, then passed through to `case`.
      def taken(value)
        @taken = true
        @branch = value
        value
      end

      # False when the switch decider raised.
      def taken? = @taken == true

      # Children still open were left by a failure exit (`next false` in a wrap, a nested
      # operation's `return`): they end here, not when the whole call ends.
      def close(value)
        return if closed?

        @children&.each { |child| child.close_open(:failed) }
        @closed = true
        @value = value ? true : false
        @duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - @started if @profile
      end

      def raised(exception)
        @exception = exception
        @inner = exception.octorail_trace if exception.respond_to?(:octorail_trace)
        @outcome = :raised
        close(nil)
      end

      def closed? = @closed == true

      # Nodes still open when the call ended were left early: by a failure exit (`failed`) or by an
      # exception (`raised`, only for the innermost open path).
      def close_open(outcome)
        children.each { |child| child.close_open(outcome) }
        return if closed?

        @outcome = outcome
        close(nil)
      end

      def outcome
        @outcome || OUTCOMES.fetch(type).call(self)
      end

      OUTCOMES = {
        step: ->(node) { node.value ? :success : :failure },
        pass: ->(_node) { :ran },
        failure: ->(_node) { :ran },
        recover: ->(node) { node.value ? :recovered : :not_recovered },
        wrap: ->(node) { node.value ? :success : :failure },
        nested: ->(node) { node.value ? :success : :failure },
        switch: ->(_node) { :success }
      }.freeze
      private_constant :OUTCOMES

      def to_h
        hash = { type:, name:, outcome:, **details }
        hash[:duration_ms] = Trace.ms(duration) if duration
        hash[:nodes] = children.map(&:to_h) unless children.empty?
        hash
      end

      private

      def details
        { branch: (branch if type == :switch && taken?), exception: exception&.class&.name, trace: inner&.to_h }
          .compact
      end
    end

    # Attached to an exception that left a traced call: `e.octorail_trace`.
    module TracedException
      attr_accessor :octorail_trace
    end

    def self.ms(seconds) = (seconds * 1000).round(3)

    attr_reader :level, :root, :terminus, :error, :failed_step, :exception

    # The operation's name, not the class: a trace holds no objects (see Node#value).
    def initialize(operation, level)
      @level = level
      @root = Node.new(:operation, operation.name || operation.inspect, level == :profile)
    end

    def operation = root.name

    def profile? = level == :profile

    def duration = root.duration

    # The call returned: close what is still open (left by a failure exit) and attach to the result.
    def finish(result)
      @terminus = result.terminus
      @error = result.error
      @failed_step = result.failed_step
      root.close_open(:failed)
      result.instance_variable_set(:@trace, self)
      result
    end

    # The call raised: the open nodes are the path to where it happened. A trace the exception
    # already carries (from a separate traced call inside a step) moves under that step's node.
    def fail(exception)
      @exception = exception
      root.close_open(:raised)
      return if exception.frozen?

      exception.extend(TracedException)
      exception.octorail_trace = self
    end

    def to_h
      {
        operation: root.name, level:, terminus:, error:, failed_step:,
        exception: exception&.class&.name, duration_ms: duration && Trace.ms(duration),
        nodes: root.children.map(&:to_h)
      }.compact
    end

    def to_s = Rendering.new(self).to_s

    def inspect = "#<#{self.class} #{operation} #{exception ? "raised #{exception.class}" : terminus}>"
  end
end

require_relative "trace/rendering"
