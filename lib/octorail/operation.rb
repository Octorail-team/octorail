# frozen_string_literal: true

require "monitor"

module Octorail
  # Guards compilation and invalidation; reentrant because compile_all! nests compile!.
  COMPILE_LOCK = Monitor.new

  class Operation
    include Runtime
    extend DSL
    # Last: its `include` / `method_added` hooks expect the rest of the class to be defined.
    extend Invalidation

    class << self
      # `call` and `nested_call` are defined once, here, and never redefined: each class reads its
      # own compiled instance (nil until compiled or after invalidation). Redefining them per class
      # would replace a test's stub of them and break it when the stub is restored.
      def call(**input)
        (@__octorail_instance || __octorail_compiled_instance).__octorail_entry(input)
      end

      # One call with a :profile trace, whatever the trace setting (console, tests).
      def call_traced(**input)
        (@__octorail_instance || __octorail_compiled_instance).__octorail_trace_call(input, :profile)
      end

      # Runs on the given ctx Hash itself (no copy): how `nested` calls an operation, and what
      # a test stubs (or calls with a hand-built ctx) to fake or check a nested operation.
      # `trace`: the outer trace's node, passed by a traced outer operation (docs/tracing.md);
      # without it the plain variant runs, whatever this operation's own trace setting.
      # `**nil`: `nested_call(id: 1)` (meant as `call`) is an ArgumentError, not a ctx Hash.
      def nested_call(ctx, trace = nil, **nil)
        raise ArgumentError, "#{self}.nested_call takes the ctx Hash, got #{ctx.inspect}" unless ctx.is_a?(Hash)
        return (@__octorail_instance || __octorail_compiled_instance).__octorail_call(ctx) unless trace

        __octorail_ensure_traced.__octorail_traced(ctx, trace)
      end

      # Marks a base class that holds shared methods and macros, not a flow: it can't declare steps,
      # can't be called, and compile_all! skips it. Not inherited.
      def abstract!
        if steps.any? || outputs.any?
          raise ArgumentError, "#{self}: abstract! must come before any declaration, and an abstract operation " \
                               "can't inherit steps or outputs"
        end

        @__octorail_abstract = true
        nil
      end

      def abstract? = equal?(Operation) || @__octorail_abstract == true

      def compile!
        COMPILE_LOCK.synchronize do
          return self if compiled?
          raise CompileError, "#{self}: is abstract, call an operation that inherits from it" if abstract?

          install_compiled_code
          install_traced_code unless setting(:trace) == :off # `call` itself runs the traced variant
          # Set last: a non-nil instance is what makes `call` skip compilation.
          @__octorail_instance = new.freeze
        end
        self
      end

      def compiled?
        !@__octorail_instance.nil?
      end

      def descendants
        subclasses.flat_map { |subclass| [subclass, *subclass.descendants] }
      end

      def to_ruby(traced: false)
        Compiler.new(self, traced:).source
      end

      private

      # First call (or first after invalidation): compile, then hand back the instance.
      def __octorail_compiled_instance
        compile!
        @__octorail_instance
      end

      # Both variants are generated now, from the same nodes, so they share OctorailRefs; the traced
      # one is installed only when needed (a traced setting, call_traced, a traced outer operation).
      def install_compiled_code
        define_result_class
        traced = Compiler.new(self, traced: true)
        @__octorail_traced_source = traced.source
        @__octorail_traced_installed = false
        define_refs_const(traced.anonymous_refs)
        redefine_method(Compiler::METHOD_NAME, Compiler.new(self).source, "octorail-generated:#{self}")
        install_entry
      end

      # With tracing on, `call` runs the traced variant (the trace level comes from the settings);
      # off, `call` runs the plain method itself (an alias: no extra frame).
      def install_entry
        level = setting(:trace)
        entry = Compiler::ENTRY_METHOD_NAME.to_sym
        remove_method(entry) if method_defined?(entry, false)
        return alias_method(entry, Compiler::METHOD_NAME) if level == :off

        source = "def #{entry}(ctx) = __octorail_trace_call(ctx, #{level.inspect})\n"
        class_eval(source, "octorail-entry:#{self}", 1)
      end

      def install_traced_code
        redefine_method(Compiler::TRACED_METHOD_NAME, @__octorail_traced_source, "octorail-traced:#{self}")
        @__octorail_traced_installed = true
      end

      # The compiled instance, with the traced variant installed.
      def __octorail_ensure_traced
        instance = @__octorail_instance || __octorail_compiled_instance
        return instance if @__octorail_traced_installed

        COMPILE_LOCK.synchronize { install_traced_code unless @__octorail_traced_installed }
        instance
      end

      # Removed first so redefining doesn't warn under -w.
      def redefine_method(name, source, file)
        name = name.to_sym
        remove_method(name) if method_defined?(name, false) || private_method_defined?(name, false)
        class_eval(source, file, 1)
      end

      def define_refs_const(refs)
        const = Compiler::REFS_CONST
        remove_const(const) if const_defined?(const, false)
        const_set(const, refs.freeze) if refs.any?
      end

      def define_result_class
        const = Compiler::RESULT_CONST
        remove_const(const) if const_defined?(const, false)
        const_set(const, Result.with_outputs(outputs)) if outputs.any?
      end
    end
  end
end
