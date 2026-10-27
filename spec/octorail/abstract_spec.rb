# frozen_string_literal: true

RSpec.describe "abstract operations" do # rubocop:disable RSpec/DescribeClass
  let(:base) do
    Class.new(Octorail::Operation) do
      abstract!

      def authorize(_ctx, admin:) = admin
      def log_failure(ctx, failed_step:) = ctx[:logged] = failed_step
    end
  end

  it "shares methods with the operations that inherit from it" do
    op = Class.new(base) do
      step :authorize, error: :forbidden
      failure :log_failure
    end

    expect(op.call(admin: true)).to be_success
    expect(op.call(admin: false)).to have_attributes(error: :forbidden)
    expect(op.call(admin: false)[:logged]).to eq(:authorize)
  end

  {
    "step :authorize" => ->(op, _inner) { op.step :authorize },
    "failure :log" => ->(op, _inner) { op.failure :log },
    "wrap :tx" => ->(op, _inner) { op.wrap(:tx) { nil } },
    "nested" => ->(op, inner) { op.nested inner },
    "switch :x" => ->(op, _inner) { op.switch(:x) { nil } },
    "output :user" => ->(op, _inner) { op.output :user }
  }.each do |declaration, declare|
    it "can't declare #{declaration}" do
      inner = Class.new(Octorail::Operation)

      expect { declare.call(base, inner) }
        .to raise_error(ArgumentError, /is abstract .*can't declare #{Regexp.escape(declaration)}/)
    end
  end

  it "can't be called" do
    expect { base.call(admin: true) }.to raise_error(Octorail::CompileError, /is abstract, call an operation/)
  end

  it "is not inherited" do
    expect(base).to be_abstract
    expect(Class.new(base)).not_to be_abstract
    expect(Octorail::Operation).to be_abstract
  end

  it "must be marked before any declaration and can't inherit steps" do
    with_step = Class.new(Octorail::Operation) { step :a }

    expect { with_step.abstract! }.to raise_error(ArgumentError, /abstract! must come before any declaration/)
    expect { Class.new(with_step).abstract! }.to raise_error(ArgumentError, /can't inherit steps/)
  end

  it "is skipped by compile_all!, while the operations under it are compiled" do
    root = Class.new(Octorail::Operation) { abstract! }
    abstract_base = Class.new(root) { abstract! }
    op = Class.new(abstract_base) { step :a }
    op.define_method(:a) { |_ctx| true }

    expect(Octorail.compile_all!(root)).to eq([op])
    expect(op).to be_compiled
  end
end
