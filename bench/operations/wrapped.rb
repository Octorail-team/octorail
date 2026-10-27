# frozen_string_literal: true

# validate → wrap(transaction) { build → persist } → pass notify, failure log.
# The "transaction" is a no-op that only yields: the measurement is the wrap mechanism itself.
module Wrapped
  module Steps
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

  # octorail / yaso / PORO: `.call(ctx) { }`, the block's result decides (yaso needs a Class).
  class Transaction
    def self.call(_ctx, **) = yield
  end

  # Trailblazer's Wrap handler: receives the circuit args, returns the wrapped signal.
  class TrailblazerTransaction
    def self.call((_ctx, _flow_options), **) = yield
  end

  # Decouplio calls a class method with a block and ignores its result.
  class DecouplioTransaction
    def self.transaction = yield
  end

  class Octorail < ::Octorail::Operation
    step :validate, error: :invalid
    wrap Transaction do
      step :build
      step :persist
    end
    pass :notify
    failure :log

    # octorail rejects `**` in step signatures, so it gets its own exact ones.
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
    include Steps

    step :validate
    step Wrap(TrailblazerTransaction) {
      step :build
      step :persist
    }
    pass :notify
    fail :log
  end

  class Yaso < ::Yaso::Service
    include Steps

    step :validate
    wrap Transaction do
      step :build
      step :persist
    end
    pass :notify
    failure :log
  end

  class Decouplio < ::Decouplio::Action
    logic do
      step :validate
      wrap :transaction, klass: DecouplioTransaction, method: :transaction do
        step :build
        step :persist
      end
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

  class Poro
    Result = Struct.new(:success, :ctx) do
      def success? = success
    end

    INSTANCE = new.freeze
    def self.call(**ctx) = INSTANCE.call(ctx)

    def call(ctx)
      params = ctx[:params]
      return failure(ctx) unless validate(ctx, params)

      ok = Transaction.call(ctx) do
        model = ctx[:model] = params
        ctx[:saved] = !model.nil?
      end
      return failure(ctx) unless ok

      ctx[:notified] = params[:email]
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
