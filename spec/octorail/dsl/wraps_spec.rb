# frozen_string_literal: true

RSpec.describe Octorail::DSL::Wraps do
  def operation(&)
    Class.new(Octorail::Operation, &)
  end

  it "records a wrap node with its steps" do
    op = operation do
      step :a
      wrap :tx, error: :locked do
        step :b
        failure :c
      end
    end

    wrap = op.steps.last
    expect(wrap).to have_attributes(wrapper: :tx, error: :locked, name: :tx)
    expect(wrap.nodes.map(&:name)).to eq(%i[b c])
    expect(op.all_steps.map(&:name)).to eq(%i[a b c])
    expect(op.step_method_names).to contain_exactly(:a, :b, :c, :tx)
  end

  it "keeps steps declared after the block at the top level" do
    op = operation do
      wrap(:tx) { step :a }
      step :b
    end

    expect(op.steps.map(&:type)).to eq(%i[wrap step])
  end

  it "rejects duplicate step names across wraps" do
    expect do
      operation do
        step :a
        wrap(:tx) { step :a }
      end
    end.to raise_error(ArgumentError, /:a is already declared/)
  end

  it "rejects duplicates inside the same open block" do
    expect do
      operation do
        wrap :tx do
          step :a
          step :a
        end
      end
    end.to raise_error(ArgumentError, /already declared/)
  end

  it "requires a block with steps" do
    expect { operation { wrap :tx } }.to raise_error(ArgumentError, /needs a block/)
    expect { operation { wrap(:tx) { nil } } }.to raise_error(ArgumentError, /has no steps/)
  end

  it "requires a method name or a callable wrapper" do
    expect { operation { wrap("tx") { step :a } } }.to raise_error(ArgumentError, /method name \(Symbol\)/)
    expect { operation { wrap(Object.new) { step :a } } }.to raise_error(ArgumentError, /respond to \.call/)
  end

  it "requires error: to be a Symbol" do
    expect { operation { wrap(:tx, error: "x") { step :a } } }.to raise_error(ArgumentError, /error: must be a Symbol/)
  end

  it "doesn't leak the open block after an error inside it" do
    op = operation
    expect { op.wrap(:tx) { raise "boom" } }.to raise_error("boom")

    op.step :after
    expect(op.steps.map(&:name)).to eq([:after])
  end
end
