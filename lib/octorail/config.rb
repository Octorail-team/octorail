# frozen_string_literal: true

module Octorail
  # Global settings (docs/configuration.md). An operation overrides them with `configure` (dsl/settings.rb).
  class Config
    # Settings an operation may override, with their allowed values.
    OPERATION_SETTINGS = { trace: Trace::LEVELS }.freeze

    attr_reader :trace

    def initialize
      @trace = :off
    end

    # Changes compiled code, so every compiled operation recompiles on its next call.
    def trace=(level)
      @trace = Config.check!(:trace, level, "Octorail.config")
      Operation.invalidate!
    end

    def self.check!(key, value, owner)
      allowed = OPERATION_SETTINGS.fetch(key)
      return value if allowed.include?(value)

      raise ArgumentError, "#{owner}: #{key} must be one of #{Octorail.key_list(allowed)}, got #{value.inspect}"
    end
  end

  def self.config = @config ||= Config.new

  def self.configure
    yield config
    config
  end
end
