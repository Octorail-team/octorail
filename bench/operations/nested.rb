# frozen_string_literal: true

# Outer: nested Inner(validate → build) → persist → pass notify, failure log.
# The failure scenario fails inside the nested operation, so the outer failure step runs.
module Nested
  module InnerSteps
    def validate(ctx, params:, **)
      return true if params[:email]

      ctx[:errors] = { email: ["is missing"] }
      false
    end

    def build(ctx, params:, **) = ctx[:model] = params
  end

  module OuterSteps
    def persist(ctx, model:, **) = ctx[:saved] = !model.nil?
    def notify(ctx, model:, **) = ctx[:notified] = model[:email]
    def log(ctx, **) = ctx[:logged] = true
  end

  class OctorailInner < ::Octorail::Operation
    step :validate, error: :invalid
    step :build

    def validate(ctx, params:)
      return true if params[:email]

      ctx[:errors] = { email: ["is missing"] }
      false
    end

    def build(ctx, params:) = ctx[:model] = params
  end

  class Octorail < ::Octorail::Operation
    nested OctorailInner
    step :persist
    pass :notify
    failure :log

    def persist(ctx, model:) = ctx[:saved] = !model.nil?
    def notify(ctx, model:) = ctx[:notified] = model[:email]
    def log(ctx) = ctx[:logged] = true
  end

  class TrailblazerInner < ::Trailblazer::Operation
    include InnerSteps

    step :validate
    step :build
  end

  class Trailblazer < ::Trailblazer::Operation
    include OuterSteps

    step Subprocess(TrailblazerInner)
    step :persist
    pass :notify
    fail :log
  end

  class YasoInner < ::Yaso::Service
    include InnerSteps

    step :validate
    step :build
  end

  class Yaso < ::Yaso::Service
    include OuterSteps

    step YasoInner
    step :persist
    pass :notify
    failure :log
  end

  class DecouplioInner < ::Decouplio::Action
    logic do
      step :validate
      step :build
    end

    def validate
      return true if ctx[:params][:email]

      ctx[:errors] = { email: ["is missing"] }
      false
    end

    def build = ctx[:model] = ctx[:params]
  end

  class Decouplio < ::Decouplio::Action
    logic do
      step DecouplioInner
      step :persist
      pass :notify
      fail :log
    end

    def persist = ctx[:saved] = !ctx[:model].nil?
    def notify = ctx[:notified] = ctx[:model][:email]
    def log = ctx[:logged] = true
  end

  # By hand: the inner object is called with the same ctx and returns a result.
  class PoroInner
    Result = Struct.new(:success, :ctx) do
      def success? = success
    end

    INSTANCE = new.freeze

    def call(ctx)
      params = ctx[:params]
      unless params[:email]
        ctx[:errors] = { email: ["is missing"] }
        return Result.new(false, ctx)
      end

      ctx[:model] = params
      Result.new(true, ctx)
    end
  end

  class Poro
    Result = PoroInner::Result

    INSTANCE = new.freeze
    def self.call(**ctx) = INSTANCE.call(ctx)

    def call(ctx)
      return failure(ctx) unless PoroInner::INSTANCE.call(ctx).success?

      model = ctx[:model]
      return failure(ctx) unless (ctx[:saved] = !model.nil?)

      ctx[:notified] = model[:email]
      Result.new(true, ctx)
    end

    private

    def failure(ctx)
      ctx[:logged] = true
      Result.new(false, ctx)
    end
  end
end
