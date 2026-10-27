# frozen_string_literal: true

# One realistic operation written idiomatically for every library:
#   validate → build → persist → pass notify, with a failure step logging errors.
# Steps do trivial work so that the measurement is the library's own overhead.

module CreateUser
  class Octorail < ::Octorail::Operation
    step :validate, error: :invalid
    step :build
    step :persist
    pass :notify
    failure :log

    def validate(ctx, params:)
      return true if params[:email]

      ctx[:errors] = { email: ["is missing"] }
      false
    end

    def build(ctx, params:) = ctx[:model] = params
    def persist(ctx, model:) = ctx[:saved] = !model.nil?
    def notify(ctx, model:) = ctx[:notified] = model[:email]
    def log(ctx) = ctx[:logged] = true
  end

  class Trailblazer < ::Trailblazer::Operation
    step :validate
    step :build
    step :persist
    pass :notify
    fail :log

    def validate(ctx, params:, **)
      return true if params[:email]

      ctx[:errors] = { email: ["is missing"] }
      false
    end

    def build(ctx, params:, **) = ctx[:model] = params
    def persist(ctx, model:, **) = ctx[:saved] = !model.nil?
    def notify(ctx, model:, **) = ctx[:notified] = model[:email]
    def log(ctx, **) = ctx[:logged] = true
  end

  class Yaso < ::Yaso::Service
    step :validate
    step :build
    step :persist
    pass :notify
    failure :log

    def validate(ctx, params:, **)
      return true if params[:email]

      ctx[:errors] = { email: ["is missing"] }
      false
    end

    def build(ctx, params:, **) = ctx[:model] = params
    def persist(ctx, model:, **) = ctx[:saved] = !model.nil?
    def notify(ctx, model:, **) = ctx[:notified] = model[:email]
    def log(ctx, **) = ctx[:logged] = true
  end

  class Decouplio < ::Decouplio::Action
    logic do
      step :validate
      step :build
      step :persist
      pass :notify
      fail :log
    end

    def validate
      return true if ctx[:params][:email]

      ctx[:errors] = { email: ["is missing"] }
      false
    end

    def build = ctx[:model] = ctx[:params]
    def persist = ctx[:saved] = !ctx[:model].nil?
    def notify = ctx[:notified] = ctx[:model][:email]
    def log = ctx[:logged] = true
  end

  # What you'd write by hand: the baseline every library is measured against.
  class Poro
    Result = Struct.new(:success, :ctx) do
      def success? = success
    end

    # One frozen instance, like octorail: no allocation per call besides ctx and the result.
    INSTANCE = new.freeze
    def self.call(**ctx) = INSTANCE.call(ctx)

    def call(ctx)
      params = ctx[:params]
      return failure(ctx) unless validate(ctx, params)

      model = ctx[:model] = params
      return failure(ctx) unless (ctx[:saved] = !model.nil?)

      ctx[:notified] = model[:email]
      Result.new(true, ctx)
    end

    private

    def validate(ctx, params)
      return true if params[:email]

      ctx[:errors] = { email: ["is missing"] }
      false
    end

    def failure(ctx)
      ctx[:logged] = true
      Result.new(false, ctx)
    end
  end
end
