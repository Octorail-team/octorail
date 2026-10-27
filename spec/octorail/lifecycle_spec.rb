# frozen_string_literal: true

RSpec.describe "compilation lifecycle" do # rubocop:disable RSpec/DescribeClass
  def operation(parent = Octorail::Operation, &)
    Class.new(parent, &)
  end

  let(:op) do
    operation do
      step :a
      def a(ctx) = ctx[:a] = 1
    end
  end

  it "compiles lazily on the first call" do
    expect { op.call }.to change(op, :compiled?).from(false).to(true)
  end

  it "compiles a child separately from its already compiled parent" do
    op.call
    child = operation(op) do
      step :b
      def b(ctx) = ctx[:b] = 2
    end

    expect(child.call.ctx).to eq(a: 1, b: 2)
    expect(op.call.ctx).to eq(a: 1)
  end

  describe "invalidation" do
    before { op.call }

    it "recompiles after a step is added" do
      op.step :b
      op.define_method(:b) { |ctx| ctx[:b] = 2 }

      expect(op).not_to be_compiled
      expect(op.call.ctx).to eq(a: 1, b: 2)
    end

    it "recompiles after a step method is redefined with a new signature" do
      op.class_eval { def a(ctx, params:) = ctx[:a] = params }

      expect(op.call(params: :new)[:a]).to eq(:new)
    end

    it "recompiles after a module overriding a step method is included" do
      op.prepend(Module.new { def a(ctx) = ctx[:a] = :prepended })

      expect(op.call[:a]).to eq(:prepended)
    end

    it "raises CompileError after a step method is removed" do
      op.__send__(:remove_method, :a)

      expect { op.call }.to raise_error(Octorail::CompileError, /has no instance method #a/)
    end

    it "cascades to compiled descendants when the parent changes" do
      child = operation(op) { pass :c }
      child.define_method(:c) { |ctx| ctx[:c] = 3 }
      child.call

      op.pass :b
      op.define_method(:b) { |ctx| ctx[:b] = 2 }

      expect(child).not_to be_compiled
      expect(child.call.ctx).to eq(a: 1, b: 2, c: 3)
    end

    it "recompiles a child when the parent redefines a step method the child uses" do
      child = operation(op)
      child.call

      op.class_eval { def a(ctx) = ctx[:a] = :changed }

      expect(child.call[:a]).to eq(:changed)
    end

    it "keeps the compiled code when an unrelated method is defined" do
      op.class_eval { def helper = 1 }

      expect(op).to be_compiled
    end

    it "does not warn about redefined methods when recompiling" do
      original = $VERBOSE
      $VERBOSE = true
      expect { op.invalidate!.call }.not_to output.to_stderr
    ensure
      $VERBOSE = original
    end
  end

  it "compiles once when many threads make the first call at the same time" do
    allow(Octorail::Compiler).to receive(:new).and_call_original
    start = Queue.new
    threads = Array.new(16) { Thread.new { start.pop && op.call } }
    16.times { start << true }

    expect(threads.map(&:value)).to all(be_success)
    # One compilation builds both variants (plain and traced): two compilers, not 32.
    expect(Octorail::Compiler).to have_received(:new).twice
  end

  describe "Octorail.compile_all!" do
    let(:root) { operation }

    it "compiles every descendant of the root" do
      first = operation(root) { step :a }.tap { |o| o.define_method(:a) { |_| true } }
      second = operation(first) { pass :b }.tap { |o| o.define_method(:b) { |_| true } }

      expect(Octorail.compile_all!(root)).to contain_exactly(first, second)
      expect([first, second]).to all(be_compiled)
    end

    it "surfaces compile errors" do
      operation(root) { step :missing }

      expect { Octorail.compile_all!(root) }.to raise_error(Octorail::CompileError)
    end
  end
end
