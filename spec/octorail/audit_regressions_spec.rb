# frozen_string_literal: true

# Regressions for bugs found by the code audit; each example failed before its fix.
RSpec.describe "audit regressions" do # rubocop:disable RSpec/DescribeClass
  def operation(parent = Octorail::Operation, &)
    Class.new(parent, &)
  end

  describe "stubbing call / nested_call before the operation is compiled" do
    let(:charge) do
      operation do
        step :charge
        def charge(ctx) = ctx[:charged] = true
      end
    end

    it "keeps a stub of nested_call when compilation happens after it is set" do
      inner = charge
      outer = operation { nested inner }
      allow(inner).to receive(:nested_call) { |ctx| Octorail::Result.new(:failure, ctx, :declined, :charge) }

      inner.call # compiles the stubbed operation

      expect(outer.call.error).to eq(:declined)
    end

    it "works normally after the stub is removed" do
      inner = charge
      outer = operation { nested inner }
      allow(inner).to receive(:nested_call).and_call_original
      inner.call
      RSpec::Mocks.space.proxy_for(inner).reset

      expect(outer.call).to be_success
      expect(inner.call).to be_success
    end

    it "counts calls through a spy across compilation" do
      op = charge
      allow(op).to receive(:call).and_call_original

      2.times { op.call }

      expect(op).to have_received(:call).twice
    end
  end

  it "rejects Ruby keywords as step names" do
    expect { operation { step :not } }.to raise_error(ArgumentError, /step :not is a Ruby keyword/)
    expect { operation { pass :class } }.to raise_error(ArgumentError, /pass :class is a Ruby keyword/)
    expect { operation { wrap(:begin) { step :a } } }.to raise_error(ArgumentError, /wrap :begin is a Ruby keyword/)
  end

  describe "failed_step / error of a wrap inside a method wrap" do
    let(:failing_wrapper) { Class.new { def self.call(_ctx) = yield && false } }

    it "keeps nil failed_step of an inner object wrapper that failed by itself" do
      inner_wrapper = failing_wrapper
      op = operation do
        wrap :outer do
          wrap(inner_wrapper, error: :inner_failed) { step :a }
        end
        def outer(_ctx) = yield
        def a(_ctx) = true
      end

      expect(op.call).to have_attributes(error: :inner_failed, failed_step: nil)
    end

    it "keeps nil error and failed_step reported by a nested operation" do
      inner = operation { step :a }
      allow(inner).to receive(:nested_call) { |ctx| Octorail::Result.new(:failure, ctx) }
      op = operation do
        wrap(:outer) { nested inner }
        def outer(_ctx) = yield
      end

      expect(op.call).to have_attributes(error: nil, failed_step: nil)
    end
  end

  it "resets the wrap outcome on every yield of a retrying wrapper" do
    retrying = Class.new { def self.call(_ctx) = 2.times { break if yield } && false }
    op = operation do
      wrap retrying, error: :commit_failed do
        step :flaky, fail_fast: true
      end
      failure :log
      def flaky(ctx) = (ctx[:attempt] = ctx.fetch(:attempt, 0) + 1) > 1
      def log(ctx) = ctx[:logged] = true
    end

    expect(op.call).to have_attributes(terminus: :failure, error: :commit_failed, failed_step: nil)
    expect(op.call[:logged]).to be(true)
  end

  it "references an operation with a temporary name through OctorailRefs" do
    inner = operation { step :a }.tap { |op| op.define_method(:a) { |_ctx| true } }
    inner.set_temporary_name("<inner op>")

    expect(operation { nested inner }.call).to be_success
  end

  describe "reopening a parent with something a subclass already declared" do
    it "rejects the duplicate step, pointing to the original" do
      parent = operation
      line = __LINE__ + 1
      operation(parent) { step :a }

      expect { parent.step :a }.to raise_error(ArgumentError, /step :a is already declared \(step :a\)\n.*:#{line}\z/)
    end

    it "lets the subclass inherit the output instead of duplicating it" do
      parent = operation
      child = operation(parent) { output :a }
      parent.output :a

      expect(child.outputs).to eq([:a])
    end
  end

  it "does not take Kernel / Object methods for step methods" do
    expect { operation { step :test }.compile! }
      .to raise_error(Octorail::CompileError, /step :test has no instance method #test \(only Kernel#test/)
    expect { operation { step :display }.compile! }.to raise_error(Octorail::CompileError, /#display/)
  end

  it "rejects an operation class as a wrapper, pointing to nested" do
    inner = operation { step :a }

    expect { operation { wrap(inner) { step :b } } }.to raise_error(ArgumentError, /is an operation.*use nested/)
  end

  describe "error message format" do
    it "names the operation in DSL errors" do
      op = operation
      stub_const("Orders::Create", op)

      expect { op.step "x" }.to raise_error(ArgumentError, /\AOrders::Create: step name must be a Symbol/)
      expect { op.pass :x, error: :e }.to raise_error(ArgumentError, /\AOrders::Create: pass :x: unknown options/)
    end

    it "says 'none' for an empty ctx" do
      op = operation do
        step :a
        def a(_ctx, params:) = params
      end

      expect { op.call }.to raise_error(Octorail::MissingKeyError, /\(ctx keys: none\)/)
    end

    it "names a subclass nested into its parent as such" do
      parent = operation
      child = operation(parent)

      expect { parent.nested child }.to raise_error(ArgumentError, /can't nest its own subclass/)
    end

    it "raises CompileError for the abstract base" do
      expect { Octorail::Operation.call }.to raise_error(Octorail::CompileError, /is abstract/)
    end
  end
end
