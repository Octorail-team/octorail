# frozen_string_literal: true

require_relative "compiler/code"
require_relative "compiler/signature"
require_relative "compiler/scopes"
require_relative "compiler/step_emitter"
require_relative "compiler/wrap_emitter"
require_relative "compiler/nested_emitter"
require_relative "compiler/switch_emitter"
require_relative "compiler/recovery_emitter"
require_relative "compiler/nested_cycles"
require_relative "compiler/tracing"

module Octorail
  # Turns an operation's nodes into Ruby source for one instance method.
  # Walks the nodes and hands each to its emitter (compiler/*_emitter.rb); the public
  # methods below are the toolkit emitters share.
  class Compiler
    METHOD_NAME = "__octorail_call"
    # What `call` runs: METHOD_NAME itself when tracing is off, else a delegate to the traced call.
    ENTRY_METHOD_NAME = "__octorail_entry"
    # The traced variant (docs/tracing.md): same flow, records a Trace into `__t` (a Trace::Node).
    TRACED_METHOD_NAME = "__octorail_traced"
    # Per-operation Result subclass constant, defined only when the operation declares outputs.
    RESULT_CONST = "OctorailResult"
    # Per-operation array of objects (wrappers, nested operations) that have no constant name.
    REFS_CONST = "OctorailRefs"
    # Each node type is compiled by its own emitter (compiler/*_emitter.rb).
    EMITTERS = {
      Nodes::Step => StepEmitter,
      Nodes::Wrap => WrapEmitter,
      Nodes::Nested => NestedEmitter,
      Nodes::Switch => SwitchEmitter
    }.freeze

    # Ruby expression for the operation's Result class.
    attr_reader :result
    # Objects to store in REFS_CONST; filled while generating the source.
    attr_reader :anonymous_refs

    include Tracing

    def initialize(operation, traced: false)
      @operation = operation
      @traced = traced
      @steps = operation.steps
      @method_nodes = operation.method_nodes
      @outputs = operation.outputs
      @result = @outputs.empty? ? "::Octorail::Result" : RESULT_CONST
      @signatures = {}
      @ids = 0
      @anonymous_refs = []
      setup_emitters
    end

    def source
      @method_nodes.each { |node| check_method!(node) }
      NestedCycles.new(@operation).check!
      code = Code.new
      header = traced? ? "def #{TRACED_METHOD_NAME}(ctx, __t)" : "def #{METHOD_NAME}(ctx)"
      code.block(header) do
        emit_nodes(code, TopScope.new(@steps, self, trace_var: ("__t" if traced?)))
        emit_success(code)
        emit_frozen_rescue(code)
      end
      code.to_s
    end

    # Under a non-jumping scope (a branch inside a recovery list) an exit only sets the flag,
    # so every node after the first runs only while the flag is unset.
    def emit_nodes(code, scope)
      return @recovery.emit(code, scope) if RecoveryEmitter.needed?(scope.nodes)

      flag = scope.var(:t) unless scope.jumps?
      scope.nodes.each_with_index { |node, index| emit_node(code, node, index, scope, unless_flag: flag) }
    end

    # Emits one node with its emitter; `unless_flag` guards it (except the first and failure steps,
    # which emit nothing by themselves).
    def emit_node(code, node, index, scope, unless_flag: nil)
      emit = -> { @emitters.fetch(node.class).emit(code, node, index, scope) }
      return emit.call if unless_flag.nil? || index.zero? || failure_step?(node)

      code.block("unless #{unless_flag}", &emit)
    end

    def failure_step?(node) = node.is_a?(Nodes::Step) && node.failure?

    # A failure step's call; it may take `error:` / `failed_step:`, filled with these expressions.
    def emit_failure_step(code, failure, error, step, scope)
      return signature(failure).emit(code, error:, failed_step: step) unless traced?

      emit_call(code, failure, scope, type: :failure, error:, failed_step: step)
    end

    # Every declared output must be in ctx before the successful result is built.
    def emit_success(code)
      @outputs.each do |name|
        code.line("__octorail_missing_output(#{name.inspect}, ctx) unless ctx.key?(#{name.inspect})")
      end
      code.line("#{@result}.new(:success, ctx)")
    end

    # `branches: false` keeps the call on one line (optional kwargs via ctx.slice), e.g. for a
    # wrapper method, where an if/else tree would duplicate the whole block.
    # Per node, not per name: the same method may be a step in two branches of a switch.
    def signature(node, branches: true)
      cache = @signatures[branches] ||= {}.compare_by_identity
      cache[node] ||= Signature.new(@operation, node, method_index(node), branches:)
    end

    # The node's position in `method_nodes`, baked into the generated error calls (missing key,
    # unknown branch), so the error names this very declaration, not another one with its name.
    def method_index(node) = @method_nodes.index { |candidate| candidate.equal?(node) }

    # Unique suffix for the locals of one wrap / nested node.
    def next_id = @ids += 1

    # A named class/module is referenced by its constant; anything else goes to REFS_CONST.
    def constant_for(object)
      name = constant_name(object)
      return "::#{name}" if name

      @anonymous_refs << object
      "#{REFS_CONST}[#{@anonymous_refs.size - 1}]"
    end

    private

    def setup_emitters
      @emitters = EMITTERS.transform_values { |emitter| emitter.new(self) }
      @recovery = RecoveryEmitter.new(self)
    end

    def constant_name(object)
      name = object.is_a?(Module) && object.name
      name if name && Object.const_defined?(name) && Object.const_get(name).equal?(object)
    rescue NameError # a temporary name (Module#set_temporary_name) is not a constant path
      nil
    end

    # Free unless raised: turns "can't modify frozen Users::Create" from an ivar write into a clear error.
    def emit_frozen_rescue(code)
      code.dedented { code.line("rescue FrozenError => e") }
      code.line("__octorail_frozen!(e)")
    end

    # Methods every object has (Kernel#test, Object#display, ...) don't count as a step's method.
    def check_method!(node)
      name = node.name
      defined = @operation.method_defined?(name) || @operation.private_method_defined?(name)
      owner = @operation.instance_method(name).owner if defined
      return if defined && !(owner >= Operation)

      builtin = " (only #{owner}##{name}, which is not a step)" if defined
      raise CompileError, "#{@operation}: #{node.type} #{name.inspect} has no instance method ##{name}#{builtin}" \
                          "#{Octorail.declared_at(node)}"
    end
  end
end
