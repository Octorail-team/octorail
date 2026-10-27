# frozen_string_literal: true

# failure steps: fail_fast, recover and the error: / failed_step: keywords.
RSpec.describe "failure step options" do # rubocop:disable RSpec/DescribeClass
  # Steps append to ctx[:trace] and fail when named in ctx[:fail].
  def operation(&)
    Class.new(Octorail::Operation) do
      class_eval(&)
      define_method(:flow_for) { |_ctx, role:| role } unless method_defined?(:flow_for)
      all_steps.grep(Octorail::Nodes::Step).map(&:name).uniq.each do |name|
        next if method_defined?(name) || private_method_defined?(name)

        define_method(name) { |ctx| (ctx[:trace] << name) && !ctx[:fail].include?(name) }
      end
    end
  end

  def run(operation, fail: [], **input) = operation.call(fail:, trace: [], **input)

  describe "error: and failed_step: keywords" do
    it "are filled from the failure, not from ctx" do
      op = operation do
        step :charge, error: :declined
        failure :log
        def log(ctx, error:, failed_step:) = ctx[:logged] = [error, failed_step]
      end

      expect(run(op, fail: [:charge])[:logged]).to eq(%i[declined charge])
      expect(op.to_ruby).to include("log(ctx, error: :declined, failed_step: :charge)")
    end

    it "carry what a wrap or a nested operation reported" do
      inner = operation { step :inner_step, error: :inner_error }
      op = operation do
        nested inner
        failure :log
        def log(ctx, error:, failed_step: nil) = ctx[:logged] = [error, failed_step]
      end

      expect(run(op, fail: [:inner_step])[:logged]).to eq(%i[inner_error inner_step])
    end

    it "are rejected on an ordinary step: as ctx keys they are reserved, it could never run" do
      op = operation do
        step :a
        def a(_ctx, error:) = error
      end

      expect { run(op) }.to raise_error(Octorail::CompileError, /step :a takes error:, which only failure steps get/)
    end
  end

  describe "failure ..., fail_fast: true" do
    let(:op) do
      operation do
        step :charge
        failure :notify, fail_fast: true
        failure :log
      end
    end

    it "cuts the failure track after it and ends with :fail_fast" do
      result = run(op, fail: [:charge])

      expect(result[:trace]).to eq(%i[charge notify])
      expect(result).to have_attributes(terminus: :fail_fast, failed_step: :charge)
    end

    it "keeps its meaning across a wrap" do
      op = operation do
        wrap(:within) do
          step :charge
          failure :notify, fail_fast: true
        end
        failure :log
        def within(_ctx) = yield
      end

      expect(run(op, fail: [:charge])).to have_attributes(terminus: :fail_fast)
      expect(run(op, fail: [:charge])[:trace]).to eq(%i[charge notify])
    end
  end

  describe "failure ..., recover: true" do
    let(:op) do
      operation do
        step :validate, error: :invalid
        step :charge_card, error: :declined
        failure :charge_wallet, recover: true
        step :reserve
        failure :log
        def charge_wallet(ctx, failed_step:)
          ctx[:trace] << :charge_wallet
          failed_step == :charge_card && !ctx[:fail].include?(:charge_wallet)
        end
      end
    end

    it "returns to the success track at the next step when truthy" do
      result = run(op, fail: [:charge_card])

      expect(result).to be_success
      expect(result[:trace]).to eq(%i[validate charge_card charge_wallet reserve])
    end

    it "goes on along the failure track when falsy" do
      result = run(op, fail: %i[charge_card charge_wallet])

      expect(result[:trace]).to eq(%i[validate charge_card charge_wallet log])
      expect(result).to have_attributes(terminus: :failure, error: :declined, failed_step: :charge_card)
    end

    it "lets the method decide what it recovers from" do
      result = run(op, fail: [:validate])

      expect(result[:trace]).to eq(%i[validate charge_wallet log])
      expect(result).to have_attributes(error: :invalid, failed_step: :validate)
    end

    it "is positional: a failure after it doesn't reach it" do
      expect(run(op, fail: [:reserve])[:trace]).to eq(%i[validate charge_card reserve log])
    end

    it "is skipped by a fail_fast step" do
      op = operation do
        step :authorize, fail_fast: true
        failure :fix, recover: true
      end

      expect(run(op, fail: [:authorize])[:trace]).to eq([:authorize])
    end

    it "with fail_fast: cuts the track only when recovery fails" do
      op = operation do
        step :charge
        failure :fix, recover: true, fail_fast: true
        step :ship
        failure :log
      end

      expect(run(op, fail: [:charge])[:trace]).to eq(%i[charge fix ship])
      expect(run(op, fail: %i[charge fix])).to have_attributes(terminus: :fail_fast)
      expect(run(op, fail: %i[charge fix])[:trace]).to eq(%i[charge fix])
    end

    it "recovers twice in one operation" do
      op = operation do
        step :a
        failure :fix_a, recover: true
        step :b
        failure :fix_b, recover: true
        step :c
      end

      expect(run(op, fail: %i[a b])[:trace]).to eq(%i[a fix_a b fix_b c])
    end

    it "works inside a wrap: the wrapper gets true after recovery" do
      op = operation do
        wrap(:within) do
          step :charge
          failure :fix, recover: true
        end
        def within(ctx) = (ctx[:committed] = yield)
      end

      expect(run(op, fail: [:charge])).to be_success
      expect(run(op, fail: [:charge])[:committed]).to be(true)
    end

    it "works inside a switch branch, and a branch inside a recovery list stops at its failure" do
      op = operation do
        switch :flow_for do
          on(:admin) do
            step :grant
            failure :fix, recover: true
          end
          on(:user) do
            step :quota
            step :after_quota
          end
        end
        failure :fallback, recover: true
        step :save
      end

      expect(run(op, role: :admin, fail: [:grant])[:trace]).to eq(%i[grant fix save])
      expect(run(op, role: :user, fail: [:quota])[:trace]).to eq(%i[quota fallback save])
    end

    it "runs the outer failure steps of a branch that failed inside a recovery list" do
      op = operation do
        step :a
        failure :fix, recover: true
        switch(:flow_for) { on(:user) { step :quota } }
        failure :log
      end

      expect(run(op, role: :user, fail: [:quota])[:trace]).to eq(%i[a quota log])
      expect(run(op, role: :user, fail: [:quota])).to have_attributes(failed_step: :quota)
    end

    it "leaves operations without recover: compiled as before" do
      op = operation do
        step :a
        failure :log
      end

      expect(op.to_ruby).not_to include("__r")
    end
  end
end
