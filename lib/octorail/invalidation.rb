# frozen_string_literal: true

module Octorail
  # Drops compiled code when what it was compiled from changes; extended into Operation.
  # These hooks run at code load time only.
  module Invalidation
    # Drops the compiled code of this operation and its descendants; their next call recompiles.
    def invalidate!
      COMPILE_LOCK.synchronize do
        # The next `call` sees no instance and compiles again.
        @__octorail_instance = nil
        subclasses.each(&:invalidate!)
      end
      self
    end

    def include(*)
      super.tap { invalidate! }
    end

    def prepend(*)
      super.tap { invalidate! }
    end

    private

    def method_added(name)
      super
      step_method_changed(name)
    end

    def method_removed(name)
      super
      step_method_changed(name)
    end

    def method_undefined(name)
      super
      step_method_changed(name)
    end

    # A step method was (re)defined or removed: recompile every compiled operation that calls it.
    def step_method_changed(name)
      [self, *descendants].each do |operation|
        operation.invalidate! if operation.compiled? && operation.step_method_names.include?(name)
      end
    end
  end
end
