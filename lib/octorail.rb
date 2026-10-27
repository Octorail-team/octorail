# frozen_string_literal: true

require_relative "octorail/version"
require_relative "octorail/errors"
require_relative "octorail/result"
require_relative "octorail/trace"
require_relative "octorail/config"
require_relative "octorail/nodes"
require_relative "octorail/dsl"
require_relative "octorail/compiler"
require_relative "octorail/runtime"
require_relative "octorail/invalidation"
require_relative "octorail/operation"

module Octorail
  # Compiles every operation under `root` (all of them by default), so compile errors
  # surface at boot or in CI instead of on the first call. Returns the compiled classes.
  def self.compile_all!(root = Operation)
    root.descendants.reject(&:abstract?).each(&:compile!)
  end
end
