# frozen_string_literal: true

module Octorail
  # A plain class rather than Data: Data.new always goes through a keyword Hash, which made
  # building the result cost more than all the compiled steps together.
  class Result
    # Result fields that must not appear as ctx keys (`:errors` is reserved with a meaning).
    RESERVED_CTX_KEYS = %i[success terminus error failed_step].freeze
    # Keys `result[]` refuses to read from ctx: they have dedicated readers.
    BUILTIN_KEYS = (RESERVED_CTX_KEYS + [:errors]).freeze

    attr_reader :terminus, :ctx, :error, :failed_step
    # The Trace of a traced call (docs/tracing.md), else nil. Not part of equality / to_h.
    attr_reader :trace

    def initialize(terminus, ctx, error = nil, failed_step = nil)
      @terminus = terminus
      @ctx = ctx
      @error = error
      @failed_step = failed_step
    end

    def success?
      terminus == :success
    end

    def failure?
      !success?
    end

    def errors
      ctx[:errors] unless success?
    end

    def [](key)
      if BUILTIN_KEYS.include?(key)
        reader = key == :success ? "success?" : key
        raise ReservedKeyError, "#{key.inspect} is a Result field, use result.#{reader}"
      end

      ctx[key]
    end

    def deconstruct_keys(keys)
      check_reserved_keys!
      return ctx.merge(builtin_fields) unless keys

      pick(keys)
    end

    def to_h
      { terminus:, ctx:, error:, failed_step: }
    end

    def ==(other)
      other.instance_of?(self.class) && to_h == other.to_h
    end
    alias eql? ==

    def hash
      [self.class, *to_h.values].hash
    end

    def inspect
      "#<#{self.class.name || "Octorail::Result"} terminus=#{terminus.inspect} error=#{error.inspect} " \
        "failed_step=#{failed_step.inspect} ctx=#{ctx.inspect}>"
    end

    # Builds the Result subclass for an operation with declared outputs:
    # a reader per output, and `[]` / pattern matching limited to those outputs.
    def self.with_outputs(outputs)
      Class.new(self) do
        const_set(:OUTPUTS, outputs.dup.freeze)
        include Outputs

        outputs.each do |name|
          class_eval("def #{name} = ctx[#{name.inspect}]", __FILE__, __LINE__) # def model = ctx[:model]
        end
      end
    end

    # A key outside the declared outputs is a mistake (a typo, or reaching into the operation's
    # internals), so `[]` and pattern matching both raise for it.
    module Outputs
      def [](key)
        return super if BUILTIN_KEYS.include?(key)

        check_output!(key)
        super
      end

      # Outputs can't be named like Result fields and other ctx keys are hidden,
      # so there is nothing to collide: no reserved-key check here.
      def deconstruct_keys(keys)
        return pick([*BUILTIN_KEYS, *self.class::OUTPUTS]) unless keys

        keys.each { |key| check_output!(key) unless BUILTIN_KEYS.include?(key) }
        pick(keys)
      end

      private

      def check_output!(key)
        outputs = self.class::OUTPUTS
        return if outputs.include?(key)

        raise UnknownOutputError, "#{key.inspect} is not an output (outputs: #{Octorail.key_list(outputs)}); " \
                                  "use result.ctx[#{key.inspect}] to debug"
      end
    end

    private

    def pick(keys)
      keys.each_with_object({}) do |key, hash|
        case key
        when :success then hash[key] = success?
        when :terminus, :error, :errors, :failed_step then hash[key] = public_send(key)
        else hash[key] = ctx[key] if ctx.key?(key)
        end
      end
    end

    def builtin_fields
      { success: success?, terminus:, error:, errors:, failed_step: }
    end

    def check_reserved_keys!
      clash = RESERVED_CTX_KEYS.select { |key| ctx.key?(key) }
      return if clash.empty?

      raise ReservedKeyError, "ctx keys #{Octorail.key_list(clash)} collide with Result fields; rename them"
    end
  end
end
