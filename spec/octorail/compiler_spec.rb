# frozen_string_literal: true

RSpec.describe Octorail::Compiler do
  # Every step appends its name to ctx[:trace]; steps listed in `fails` return false.
  def operation(parent = Octorail::Operation, fails: [], &)
    Class.new(parent) do
      class_eval(&)
      steps.each do |s|
        next if method_defined?(s.name)

        define_method(s.name) do |ctx|
          ctx[:trace] << s.name
          !fails.include?(s.name)
        end
      end
    end
  end

  def run(operation) = operation.call(trace: [])

  describe "success path" do
    it "runs step and pass in order and skips failure steps" do
      op = operation do
        step :a
        failure :log
        pass :b
        step :c
      end

      result = run(op)
      expect(result).to be_success
      expect(result[:trace]).to eq(%i[a b c])
      expect(result).to have_attributes(terminus: :success, error: nil, failed_step: nil)
    end

    it "ignores the return value of pass" do
      op = operation(fails: [:b]) do
        pass :b
        step :c
      end

      expect(run(op)[:trace]).to eq(%i[b c])
    end
  end

  describe "failure path" do
    let(:op) do
      operation(fails: [:b]) do
        step :a
        failure :log_early
        step :b, error: :invalid
        failure :log_first
        step :c
        failure :log_last
      end
    end

    it "stops at the failing step and runs only failure steps declared after it" do
      result = run(op)

      expect(result).to be_failure
      expect(result[:trace]).to eq(%i[a b log_first log_last])
    end

    it "sets error from the DSL and failed_step" do
      expect(run(op)).to have_attributes(terminus: :failure, error: :invalid, failed_step: :b)
    end

    it "defaults error to :failure" do
      expect(run(operation(fails: [:a]) { step :a })).to have_attributes(error: :failure, failed_step: :a)
    end

    it "treats nil as failure" do
      op = Class.new(Octorail::Operation) do
        step :find
        def find(ctx) = ctx[:user] = nil
      end

      expect(op.call).to have_attributes(failed_step: :find)
    end

    it "exposes ctx[:errors] set by the failing step" do
      op = Class.new(Octorail::Operation) do
        step :validate, error: :invalid

        def validate(ctx)
          ctx[:errors] = { email: ["is invalid"] }
          false
        end
      end

      expect(op.call.errors).to eq(email: ["is invalid"])
    end

    it "ignores the return value of failure steps" do
      op = Class.new(Octorail::Operation) do
        step :a
        failure :recover

        def a(_ctx) = false
        def recover(_ctx) = true
      end

      expect(op.call).to be_failure
    end
  end

  describe "fail_fast" do
    let(:op) do
      operation(fails: [:find]) do
        step :find, error: :not_found, fail_fast: true
        failure :log
        step :persist
      end
    end

    it "skips failure steps and ends with :fail_fast" do
      result = run(op)

      expect(result[:trace]).to eq([:find])
      expect(result).to have_attributes(terminus: :fail_fast, error: :not_found, failed_step: :find)
      expect(result).to be_failure
    end

    it "does not change the success path" do
      expect(run(operation { step :find, fail_fast: true })).to have_attributes(terminus: :success)
    end

    it "only affects its own step" do
      op = operation(fails: [:persist]) do
        step :find, fail_fast: true
        failure :log
        step :persist
        failure :log_persist
      end

      expect(run(op)).to have_attributes(terminus: :failure, failed_step: :persist)
      expect(run(op)[:trace]).to eq(%i[find persist log_persist])
    end
  end

  describe "inheritance" do
    it "does not run parent failure steps for a child step appended after them" do
      parent = operation do
        step :a
        failure :log
      end
      child = operation(parent, fails: [:audit]) { step :audit }

      result = run(child)
      expect(result[:trace]).to eq(%i[a audit])
      expect(result.failed_step).to eq(:audit)
    end
  end

  it "calls private step methods" do
    op = Class.new(Octorail::Operation) do
      step :a

      private

      def a(ctx) = ctx[:done] = true
    end

    expect(op.call[:done]).to be(true)
  end

  it "does not mutate the caller's hash" do
    op = Class.new(Octorail::Operation) do
      step :a
      def a(ctx) = ctx[:model] = :user
    end
    input = { params: {} }.freeze

    expect(op.call(**input)[:model]).to eq(:user)
    expect(input).to eq(params: {})
  end

  it "raises CompileError for a step without a method" do
    op = Class.new(Octorail::Operation) { step :missing }

    expect { op.call }.to raise_error(Octorail::CompileError, /step :missing has no instance method #missing/)
  end

  it "raises CompileError for a failure step without a method" do
    op = Class.new(Octorail::Operation) do
      step :a
      failure :missing
      def a(_ctx) = true
    end

    expect { op.call }.to raise_error(Octorail::CompileError, /failure :missing has no instance method #missing/)
  end

  it "refuses to compile the abstract base class" do
    expect { Octorail::Operation.call }.to raise_error(Octorail::Error, /abstract/)
  end

  describe "#to_ruby" do
    let(:op) do
      Class.new(Octorail::Operation) do
        step :validate, error: :invalid
        pass :notify
        failure :log
        step :persist
        %i[validate notify log persist].each { |name| define_method(name) { |_ctx| true } }
      end
    end

    let(:expected) { <<~RUBY }
      def __octorail_call(ctx)
        unless validate(ctx)
          log(ctx)
          return ::Octorail::Result.new(:failure, ctx, :invalid, :validate)
        end
        notify(ctx)
        unless persist(ctx)
          return ::Octorail::Result.new(:failure, ctx, :failure, :persist)
        end
        ::Octorail::Result.new(:success, ctx)
      rescue FrozenError => e
        __octorail_frozen!(e)
      end
    RUBY

    it "generates plain Ruby" do
      expect(op.to_ruby).to eq(expected)
    end
  end
end
