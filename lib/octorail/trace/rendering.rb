# frozen_string_literal: true

module Octorail
  class Trace
    # Trace#to_s: the path as a tree.
    #
    #   Orders::Checkout  12.4 ms
    #   ├── ✓ validate  0.1 ms
    #   ├── switch flow_for → :admin
    #   │   └── ✗ grant_all
    #   └── failure error=:failure failed_step=:grant_all
    class Rendering
      MARKS = {
        success: "✓", failure: "✗", ran: "·", recovered: "↺", not_recovered: "↺",
        failed: "✗", raised: "!"
      }.freeze
      KINDS = { nested: "nested ", failure: "failure " }.freeze

      def initialize(trace, lines = [])
        @trace = trace
        @lines = lines
      end

      def to_s
        @lines << with_duration(@trace.root.name, @trace.duration)
        render_body("")
        "#{@lines.join("\n")}\n"
      end

      # The tree under the root line; also used for a trace carried in from a separate call.
      def render_body(indent)
        nodes = @trace.root.children
        last = summary? ? nil : nodes.size - 1
        nodes.each_with_index { |node, index| render(node, indent, index == last, []) }
        @lines << "#{indent}└── #{summary}" if summary?
      end

      private

      def render(node, indent, last, wraps)
        @lines << "#{indent}#{branch_mark(last)}#{with_duration(label(node, wraps), node.duration)}"
        render_children(node, indent + child_mark(last), node.type == :wrap ? [*wraps, node] : wraps)
      end

      def render_children(node, indent, wraps)
        render_inner(node.inner, indent) if node.inner
        node.children.each_with_index do |child, index|
          render(child, indent, index == node.children.size - 1, wraps)
        end
      end

      def branch_mark(last) = last ? "└── " : "├── "
      def child_mark(last) = last ? "    " : "│   "

      def render_inner(inner, indent)
        @lines << "#{indent}└── #{with_duration(inner.root.name, inner.duration)}"
        Rendering.new(inner, @lines).render_body("#{indent}    ")
      end

      def label(node, wraps)
        case node.type
        when :switch then "switch #{node.name}#{" → #{node.branch.inspect}" if node.taken?}#{suffix(node, wraps)}"
        when :wrap then "wrap #{node.name} → #{wrap_result(node)}"
        when :recover then "#{mark(node)} recover #{node.name} (#{node.outcome.to_s.tr("_", " ")})"
        else plain_label(node, wraps)
        end
      end

      def plain_label(node, wraps)
        "#{mark(node)} #{KINDS[node.type]}#{node.name}#{suffix(node, wraps) unless node.type == :nested}"
      end

      def mark(node) = MARKS.fetch(node.outcome, "?")

      def wrap_result(node)
        node.outcome == :raised ? "raised" : node.value.inspect
      end

      def suffix(node, wraps = [])
        case node.outcome
        when :raised then " (raised #{(node.exception || @trace.exception).class}#{rescuer(wraps)})"
        when :failed then " (left on failure)"
        else ""
        end
      end

      # A raise that didn't leave the call was rescued by the innermost enclosing wrap that ended normally.
      def rescuer(wraps)
        wrap = wraps.reverse.find { |node| node.outcome != :raised }
        wrap ? ", rescued by #{wrap.name}" : ""
      end

      def summary?
        @trace.exception || @trace.terminus
      end

      def summary
        return "raised #{@trace.exception.class}: #{@trace.exception.message}" if @trace.exception

        details = [("error=#{@trace.error.inspect}" if @trace.error),
                   ("failed_step=#{@trace.failed_step.inspect}" if @trace.failed_step)].compact
        [@trace.terminus, *details].join(" ")
      end

      def with_duration(text, seconds)
        seconds ? "#{text}  #{Trace.ms(seconds)} ms" : text
      end
    end
  end
end
