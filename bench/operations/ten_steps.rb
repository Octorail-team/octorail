# frozen_string_literal: true

# Ten trivial steps, mirroring yaso's own benchmark: shows how overhead grows per step.
module TenSteps
  NAMES = %i[one two three four five six seven eight nine ten].freeze

  class Octorail < ::Octorail::Operation
    NAMES.each { |name| step name }
    NAMES.each { |name| class_eval("def #{name}(ctx) = ctx[#{name.inspect}] = true", __FILE__, __LINE__) }
  end

  class Trailblazer < ::Trailblazer::Operation
    NAMES.each { |name| step name }
    NAMES.each { |name| class_eval("def #{name}(ctx, **) = ctx[#{name.inspect}] = true", __FILE__, __LINE__) }
  end

  class Yaso < ::Yaso::Service
    NAMES.each { |name| step name }
    NAMES.each { |name| class_eval("def #{name}(ctx, **) = ctx[#{name.inspect}] = true", __FILE__, __LINE__) }
  end

  class Decouplio < ::Decouplio::Action
    logic { NAMES.each { |name| step name } }
    NAMES.each { |name| class_eval("def #{name} = ctx[#{name.inspect}] = true", __FILE__, __LINE__) }
  end

  class Poro
    Result = Struct.new(:success, :ctx) do
      def success? = success
    end

    # One frozen instance, like octorail: no allocation per call besides ctx and the result.
    INSTANCE = new.freeze
    def self.call(**ctx) = INSTANCE.call(ctx)

    # Unrolled by hand, like the code octorail generates.
    class_eval(<<~RUBY, __FILE__, __LINE__ + 1)
      def call(ctx)
        #{NAMES.map { |name| "ctx[#{name.inspect}] = true" }.join("\n")}
        Result.new(true, ctx)
      end
    RUBY
  end
end
