# frozen_string_literal: true

require_relative "dsl/steps"
require_relative "dsl/outputs"
require_relative "dsl/wraps"
require_relative "dsl/nested"
require_relative "dsl/switches"
require_relative "dsl/settings"

module Octorail
  # Class-level DSL, extended into Operation. Only records declarations; compilation happens later.
  # Each feature lives in its own module under dsl/.
  module DSL
    include Steps
    include Outputs
    include Wraps
    include Nested
    include Switches
    include Settings

    METHOD_NAME = /\A[a-z_][a-zA-Z0-9_]*[?!]?\z/
    # Called bare in generated code, these would parse as syntax (`not(ctx)`, `defined?(ctx)`, `super`).
    RUBY_KEYWORDS = %i[
      __ENCODING__ __FILE__ __LINE__ alias and begin break case class def defined? do else elsif end ensure
      false for if in module next nil not or redo rescue retry return self super then true undef unless
      until when while yield
    ].freeze
    # Frames from the gem itself are skipped when looking for where a node was declared.
    GEM_DIR = File.expand_path("..", __dir__)
    LOCATION_FRAMES = 50

    private

    # An abstract operation holds shared methods and macros only; the flow is declared in the
    # operations that inherit from it, so each shows its whole flow.
    def check_not_abstract!(what)
      return unless abstract?

      raise ArgumentError, "#{self}: is abstract (shared methods and macros only), so it can't declare #{what}; " \
                           "declare it in the operations that inherit from it"
    end

    # "path:line" of the DSL call outside the gem. When a macro declared it (a method called from
    # the class body), also the class body line: "macros.rb:6 (via app/operations/x.rb:12)".
    def declaration_location
      frames = caller_locations(1, LOCATION_FRAMES).reject { |frame| path_of(frame).start_with?(GEM_DIR) }
      return if frames.empty?

      site = frames.first
      body = frames.find { |frame| frame.label.to_s.start_with?("<class:", "<module:") }
      return format_location(site) if body.nil? || body.equal?(site)

      "#{format_location(site)} (via #{format_location(body)})"
    end

    def format_location(frame)
      "#{path_of(frame).delete_prefix("#{Dir.pwd}/")}:#{frame.lineno}"
    end

    # absolute_path is nil for eval'd code; path then holds the file name given to eval.
    def path_of(frame) = (frame.absolute_path || frame.path).to_s

    def check_name!(name, kind)
      unless name.is_a?(Symbol) && METHOD_NAME.match?(name)
        raise ArgumentError, "#{self}: #{kind} name must be a Symbol method name, got #{name.inspect}"
      end
      return unless RUBY_KEYWORDS.include?(name)

      raise ArgumentError, "#{self}: #{kind} #{name.inspect} is a Ruby keyword, pick another name"
    end
  end
end
