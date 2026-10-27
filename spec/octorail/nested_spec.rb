# frozen_string_literal: true

RSpec.describe "nested" do # rubocop:disable RSpec/DescribeClass
  # Steps append to ctx[:trace]; steps named in `fails` return false.
  def operation(parent = Octorail::Operation, fails: [], &)
    Class.new(parent) do
      class_eval(&)
      all_steps.grep(Octorail::Nodes::Step).each do |s|
        next if method_defined?(s.name) || private_method_defined?(s.name)

        define_method(s.name) do |ctx|
          ctx[:trace] << s.name
          !fails.include?(s.name)
        end
      end
    end
  end

  def run(operation) = operation.call(trace: [])

  let(:charge) do
    operation do
      step :charge, error: :declined
      failure :refund
      def charge(ctx, amount:)
        ctx[:trace] << :charge
        ctx[:charged] = amount
        amount < 100
      end
    end
  end

  it "runs the nested operation on the same ctx" do
    inner = charge
    result = operation do
      step :validate
      nested inner
      step :receipt
      def receipt(ctx, charged:) = ctx[:receipt] = charged
    end.call(trace: [], amount: 10)

    expect(result).to be_success
    expect(result[:trace]).to eq(%i[validate charge])
    expect(result[:receipt]).to eq(10)
  end

  it "reports the inner error and failed_step, after running both failure tracks" do
    inner = charge
    result = operation do
      nested inner
      failure :log
    end.call(trace: [], amount: 500)

    expect(result).to have_attributes(terminus: :failure, error: :declined, failed_step: :charge)
    expect(result[:trace]).to eq(%i[charge refund log])
  end

  it "replaces the error with error:, keeping the inner failed_step" do
    inner = charge
    result = operation { nested inner, error: :payment_failed }.call(trace: [], amount: 500)

    expect(result).to have_attributes(error: :payment_failed, failed_step: :charge)
  end

  it "treats an inner fail_fast as an ordinary failure outside" do
    inner = operation(fails: [:find]) { step :find, error: :not_found, fail_fast: true }
    result = run(operation do
      nested inner
      failure :log
    end)

    expect(result).to have_attributes(terminus: :failure, error: :not_found, failed_step: :find)
    expect(result[:trace]).to eq(%i[find log])
  end

  it "skips the outer failure steps with fail_fast: true" do
    inner = operation(fails: [:find]) { step :find }
    result = run(operation do
      nested inner, fail_fast: true
      failure :log
    end)

    expect(result).to have_attributes(terminus: :fail_fast, failed_step: :find)
    expect(result[:trace]).to eq([:find])
  end

  it "checks the inner outputs on its own success" do
    inner = operation do
      output :charge_id
      step :charge
    end

    expect { run(operation { nested inner }) }.to raise_error(Octorail::MissingOutputError, /:charge_id/)
  end

  it "fails a surrounding wrap, so the wrapper rolls back" do
    inner = operation(fails: [:charge]) { step :charge }
    wrapper = Object.new
    def wrapper.call(ctx) = yield || ((ctx[:trace] << :rollback) && false)
    result = run(operation { wrap(wrapper) { nested inner } })

    expect(result).to have_attributes(terminus: :failure, failed_step: :charge)
    expect(result[:trace]).to eq(%i[charge rollback])
  end

  it "keeps fail_fast: true meaningful inside a wrap" do
    inner = operation(fails: [:charge]) { step :charge }
    result = run(operation do
      wrap(->(_ctx, &blk) { blk.call }) { nested inner, fail_fast: true }
      failure :log
    end)

    expect(result).to have_attributes(terminus: :fail_fast)
    expect(result[:trace]).to eq([:charge])
  end

  it "sees changes to the nested operation without recompiling the outer one" do
    inner = operation { step :charge }
    outer = operation { nested inner }
    run(outer)

    inner.class_eval { def charge(_ctx) = false }

    expect(run(outer)).to be_failure
    expect(outer).to be_compiled
  end

  describe ".nested_call" do
    it "runs on the given Hash itself" do
      ctx = { trace: [], amount: 10 }
      result = charge.nested_call(ctx)

      expect(result).to be_success
      expect(ctx).to include(charged: 10)
      expect(result.ctx).to equal(ctx)
    end

    it "refuses anything but a Hash" do
      expect { charge.nested_call([]) }.to raise_error(ArgumentError, /takes the ctx Hash, got \[\]/)
    end

    it "is what a test stubs to fake the nested operation" do
      inner = charge
      outer = operation do
        nested inner
        failure :log
      end
      allow(inner).to receive(:nested_call) do |ctx|
        ctx[:charged] = :fake
        Octorail::Result.new(:failure, ctx, :declined, :charge)
      end

      result = run(outer)

      expect(result).to have_attributes(error: :declined, failed_step: :charge)
      expect(result[:trace]).to eq([:log])
      expect(result[:charged]).to eq(:fake)
    end
  end

  describe "#to_ruby" do
    it "calls the operation by its constant and reads its result" do
      stub_const("Billing::Charge", charge)
      op = operation do
        nested Billing::Charge, error: :payment_failed
        failure :log
      end

      expect(op.to_ruby).to eq(<<~RUBY)
        def __octorail_call(ctx)
          __n1 = ::Billing::Charge.nested_call(ctx)
          unless __n1.success?
            log(ctx)
            return ::Octorail::Result.new(:failure, ctx, :payment_failed, __n1.failed_step)
          end
          ::Octorail::Result.new(:success, ctx)
        rescue FrozenError => e
          __octorail_frozen!(e)
        end
      RUBY
    end

    it "references an anonymous operation through OctorailRefs" do
      inner = charge

      expect(operation { nested inner }.to_ruby).to include("__n1 = OctorailRefs[0].nested_call(ctx)")
    end
  end
end
