# frozen_string_literal: true

module Octorail
  # Private instance helpers that generated code calls on the failure paths.
  module Runtime
    # A traced call: runs the traced variant into a new Trace, attaches it to the result, or to the
    # exception that left the call (then re-raised as is).
    def __octorail_trace_call(ctx, level)
      self.class.__send__(:__octorail_ensure_traced)
      trace = Trace.new(self.class, level)
      trace.finish(__octorail_traced(ctx, trace.root))
    rescue ::Exception => e # rubocop:disable Lint/RescueException
      trace&.fail(e)
      raise
    end

    private

    # Called from generated code on FrozenError: only an ivar write on this very instance is ours to explain.
    def __octorail_frozen!(error)
      raise error unless error.receiver.equal?(self)

      raise FrozenOperationError, "#{self.class}: a step tried to set an instance variable, but operations " \
                                  "are stateless (one frozen instance is shared by all calls). " \
                                  "Store data in ctx, pass dependencies through ctx with keyword defaults."
    end

    # Called from generated code when an operation succeeds without a declared output.
    def __octorail_missing_output(name, ctx)
      raise MissingOutputError, "#{self.class}: succeeded without setting output #{name.inspect} " \
                                "(ctx keys: #{Octorail.key_list(ctx.keys)})"
    end

    # Called from generated code when a switch decider returns a value with no branch.
    # `index`: the switch's position in method_nodes (the declaration is looked up only here).
    def __octorail_unknown_branch(index, value)
      node = self.class.method_nodes.fetch(index)
      raise UnknownBranchError, "#{self.class}: switch #{node.decider.inspect} returned #{value.inspect}, " \
                                "branches: #{Octorail.key_list(node.keys)}#{Octorail.declared_at(node)}"
    end

    # Called from generated code when a step's required keyword is absent from ctx.
    # `index`: the step's position in method_nodes, as for __octorail_unknown_branch;
    # the step's name is passed too, only so that the generated code reads well.
    def __octorail_missing_key(index, key, ctx, _step = nil)
      node = self.class.method_nodes.fetch(index)
      raise MissingKeyError, "#{self.class}: #{node.type} #{node.name.inspect} requires #{key.inspect}, " \
                             "but ctx has no #{key.inspect} (ctx keys: #{Octorail.key_list(ctx.keys)})" \
                             "#{Octorail.declared_at(node)}"
    end
  end
end
