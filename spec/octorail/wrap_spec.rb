# frozen_string_literal: true

RSpec.describe "wrap" do # rubocop:disable RSpec/DescribeClass
  # A fake transaction: records what happened, rolls back (drops ctx[:db] writes) when the block fails.
  let(:transaction) do
    Class.new do
      def self.call(ctx)
        ctx[:trace] << :begin
        snapshot = ctx[:db].dup
        if yield
          ctx[:trace] << :commit
          true
        else
          ctx[:db].replace(snapshot)
          ctx[:trace] << :rollback
          false
        end
      end
    end
  end

  # Steps append to ctx[:trace]; steps named in `fails` return false; `write_*` steps also write to ctx[:db].
  def operation(fails: [], &)
    Class.new(Octorail::Operation) do
      class_eval(&)
      all_steps.each do |s|
        next if method_defined?(s.name) || private_method_defined?(s.name)

        define_method(s.name) do |ctx|
          ctx[:trace] << s.name
          ctx[:db] << s.name if s.name.to_s.start_with?("write")
          !fails.include?(s.name)
        end
      end
    end
  end

  def run(operation) = operation.call(trace: [], db: [])

  describe "with a wrapper class" do
    it "runs the steps inside the wrapper and commits" do
      tx = transaction
      result = run(operation do
        step :validate
        wrap(tx) do
          step :write_order
          step :write_payment
        end
        step :notify
      end)

      expect(result).to be_success
      expect(result[:trace]).to eq(%i[validate begin write_order write_payment commit notify])
      expect(result[:db]).to eq(%i[write_order write_payment])
    end

    it "rolls back when a step inside fails and reports that step" do
      tx = transaction
      result = run(operation(fails: [:write_payment]) do
        wrap(tx) do
          step :write_order
          step :write_payment, error: :declined
          failure :inner_log
        end
        failure :outer_log
        step :notify
      end)

      expect(result[:trace]).to eq(%i[begin write_order write_payment inner_log rollback outer_log])
      expect(result[:db]).to eq([])
      expect(result).to have_attributes(terminus: :failure, error: :declined, failed_step: :write_payment)
    end

    it "references a named wrapper by its constant" do
      stub_const("TestTransaction", transaction)
      op = operation do
        wrap(TestTransaction) { step :write_order }
      end

      expect(op.to_ruby).to include("__w1_ok = ::TestTransaction.call(ctx) do")
    end
  end

  describe "with a wrapper method" do
    let(:op) do
      operation(fails: [:write_payment]) do
        wrap :within do
          step :write_payment
        end

        def within(ctx, label: :default)
          ctx[:trace] << label
          yield
        end
      end
    end

    it "calls the operation method, resolving its signature like a step's" do
      expect(op.call(trace: [], db: [], label: :custom)[:trace]).to eq(%i[custom write_payment])
      expect(op.to_ruby).to include("__w1_ok = within(ctx, **ctx.slice(:label)) do")
    end

    it "reports the failed step from inside" do
      expect(run(op)).to have_attributes(error: :failure, failed_step: :write_payment)
    end
  end

  describe "the wrapper's return value decides" do
    it "fails the wrap on falsy even when all steps passed, with the wrap's own error and name" do
      result = run(operation do
        wrap :refuse, error: :locked do
          step :write_order
        end
        failure :log
        def refuse(_ctx) = yield && false
      end)

      expect(result).to have_attributes(terminus: :failure, error: :locked, failed_step: :refuse)
      expect(result[:trace]).to eq(%i[write_order log])
    end

    it "lets the wrapper recover from a failed step" do
      result = run(operation(fails: [:charge]) do
        wrap :recovering do
          step :charge
        end
        step :notify
        def recovering(_ctx) = yield || true
      end)

      expect(result).to be_success
      expect(result[:trace]).to eq(%i[charge notify])
    end

    it "uses nil as failed_step when a wrapper object fails by itself" do
      refuse = Class.new { def self.call(_ctx) = yield && false }
      result = run(operation { wrap(refuse) { step :write_order } })

      expect(result).to have_attributes(error: :failure, failed_step: nil)
    end
  end

  describe "fast track inside a wrap" do
    it "fail_fast rolls back and skips failure steps inside and outside" do
      tx = transaction
      result = run(operation(fails: [:find]) do
        wrap(tx) do
          step :find, error: :not_found, fail_fast: true
          failure :inner_log
        end
        failure :outer_log
      end)

      expect(result[:trace]).to eq(%i[begin find rollback])
      expect(result).to have_attributes(terminus: :fail_fast, error: :not_found, failed_step: :find)
    end
  end

  describe "nesting" do
    it "rolls back inner wraps first and reports the innermost failed step" do
      outer = transaction
      inner = Class.new do
        def self.call(ctx)
          ok = yield
          ctx[:trace] << (ok ? :inner_done : :inner_undo)
          ok
        end
      end
      result = run(operation(fails: [:ship]) do
        wrap(outer) do
          step :write_order
          wrap(inner) do
            step :charge
            step :ship, error: :carrier_down
          end
        end
      end)

      expect(result[:trace]).to eq(%i[begin write_order charge ship inner_undo rollback])
      expect(result).to have_attributes(error: :carrier_down, failed_step: :ship)
    end
  end

  it "lets exceptions fly through the wrapper, which may rescue them" do
    timeout = Class.new do
      def self.call(_ctx)
        yield
      rescue ArgumentError
        false
      end
    end
    op = operation do
      wrap(timeout, error: :timeout) { step :charge }
      def charge(_ctx) = raise(ArgumentError)
    end

    expect(op.call(trace: [], db: [])).to have_attributes(error: :timeout, failed_step: nil)
  end

  it "accepts any object responding to call" do
    wrapper = Object.new
    def wrapper.call(_ctx) = yield
    op = operation { wrap(wrapper) { step :write_order } }

    expect(run(op)).to be_success
    expect(op.to_ruby).to include("OctorailRefs[0].call(ctx) do")
  end

  it "recompiles when the wrapper method is redefined" do
    op = operation do
      wrap(:within) { step :write_order }
      def within(_ctx) = yield
    end
    run(op)

    op.class_eval { def within(_ctx) = yield && false }

    expect(run(op)).to be_failure
  end

  it "raises CompileError when the wrapper method is missing" do
    op = operation { wrap(:transaction) { step :write_order } }

    expect { run(op) }.to raise_error(Octorail::CompileError, /wrap :transaction has no instance method/)
  end

  describe "#to_ruby" do
    let(:op) do
      operation do
        wrap :within, error: :locked do
          step :charge, error: :declined
          failure :undo
        end
        failure :log
        def within(_ctx) = yield
      end
    end

    let(:expected) { <<~RUBY }
      def __octorail_call(ctx)
        __w1_t = __w1_e = __w1_s = nil
        __w1_ok = within(ctx) do
          __w1_t = __w1_e = __w1_s = nil
          unless charge(ctx)
            undo(ctx)
            __w1_t = :failure
            __w1_e = :declined
            __w1_s = :charge
            next false
          end
          true
        end
        unless __w1_ok
          log(ctx)
          return ::Octorail::Result.new(:failure, ctx, __w1_t ? __w1_e : :locked, __w1_t ? __w1_s : :within)
        end
        ::Octorail::Result.new(:success, ctx)
      rescue FrozenError => e
        __octorail_frozen!(e)
      end
    RUBY

    it "compiles the wrap into a block with next instead of return" do
      expect(op.to_ruby).to eq(expected)
    end
  end
end
