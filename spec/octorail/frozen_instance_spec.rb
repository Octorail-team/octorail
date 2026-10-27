# frozen_string_literal: true

RSpec.describe "frozen operation instance" do # rubocop:disable RSpec/DescribeClass
  def operation(&)
    Class.new(Octorail::Operation) do
      step :run
      class_eval(&)
    end
  end

  it "explains an instance variable write in a step" do
    op = operation { def run(_ctx) = @client = :api }

    expect { op.call }.to raise_error(Octorail::FrozenOperationError, /operations are stateless.*Store data in ctx/)
  end

  it "explains ||= memoization in a helper" do
    op = operation do
      def run(ctx) = ctx[:client] = client
      def client = @client ||= :api
    end

    expect { op.call }.to raise_error(Octorail::FrozenOperationError)
  end

  it "keeps the original FrozenError as the cause" do
    op = operation { def run(_ctx) = @client = :api }

    expect { op.call }.to(raise_error { |error| expect(error.cause).to be_a(FrozenError) })
  end

  it "re-raises FrozenError from other objects untouched" do
    op = operation { def run(ctx) = ctx[:params] << :x }

    expect { op.call(params: [].freeze) }.to raise_error(FrozenError) { |error|
      expect(error).not_to be_a(Octorail::FrozenOperationError)
    }
  end

  it "shares one frozen instance between calls" do
    op = operation { def run(ctx) = ctx[:self] = self }

    expect(op.call[:self]).to equal(op.call[:self]).and be_frozen
  end

  it "leaves Op.new unfrozen for unit-testing a step" do
    op = operation { def run(ctx, params:) = ctx[:got] = params }

    expect(op.new).not_to be_frozen
    expect(op.new.run({}, params: 1)).to eq(1)
  end
end
