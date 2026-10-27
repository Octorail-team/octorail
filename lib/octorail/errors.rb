# frozen_string_literal: true

module Octorail
  # Every Octorail error is a mistake in code, not a business failure (those are failure results).
  # Like NotImplementedError, they derive from ScriptError so that a bare `rescue` / `rescue
  # StandardError` (a timeout wrapper, a controller, `retry_on StandardError`) can't swallow or
  # retry them: they reach the top-level handler (Rails, Sidekiq, Sentry rescue Exception).
  class Error < ScriptError; end

  # Suffix for error messages about a declared node: where its step/wrap/nested line is.
  def self.declared_at(node)
    node&.location ? "\n  declared at #{node.location}" : ""
  end

  # Key lists in error messages: ":a, :b", or "none".
  def self.key_list(keys)
    keys.empty? ? "none" : keys.map(&:inspect).join(", ")
  end

  # Raised while compiling an operation: unsupported step signature, unknown step method, etc.
  class CompileError < Error; end

  # Raised at runtime when a step requires a keyword that ctx doesn't have.
  class MissingKeyError < Error; end

  # Raised when ctx holds a key that collides with a Result field.
  class ReservedKeyError < Error; end

  # Raised when an operation with declared outputs succeeds without setting one of them.
  class MissingOutputError < Error; end

  # Raised by `result[key]` when the operation declares outputs and `key` isn't one of them.
  class UnknownOutputError < Error; end

  # Raised when a switch decider returns a value that has no on(...) branch.
  class UnknownBranchError < Error; end

  # Raised when a step writes an instance variable: the operation instance is shared and frozen.
  class FrozenOperationError < Error; end
end
