# frozen_string_literal: true

module Octorail
  class Compiler
    # Collects generated source line by line and keeps track of indentation.
    class Code
      def initialize
        @lines = []
        @depth = 0
      end

      def line(text)
        @lines << "#{"  " * @depth}#{text}"
        self
      end

      def indented
        @depth += 1
        yield
        self
      ensure
        @depth -= 1
      end

      # For `rescue` / `else` lines that sit one level out from the body.
      def dedented
        @depth -= 1
        yield
        self
      ensure
        @depth += 1
      end

      # header ... end
      def block(header, &)
        line(header)
        indented(&)
        line("end")
      end

      # if condition ... else ... end
      def if_else(condition, on_true, on_false)
        line("if #{condition}")
        indented(&on_true)
        line("else")
        indented(&on_false)
        line("end")
      end

      def to_s
        "#{@lines.join("\n")}\n"
      end
    end
  end
end
