# frozen_string_literal: true

RSpec.describe Octorail::DSL::Nested do
  def operation(parent = Octorail::Operation, &)
    Class.new(parent, &)
  end

  let(:inner) { operation { step :a } }

  it "records a nested node in place" do
    nested_op = inner
    op = operation do
      step :b
      nested nested_op, error: :failed, fail_fast: true
      wrap(:tx) { nested nested_op }
    end

    expect(op.steps[1]).to have_attributes(type: :nested, operation: nested_op, error: :failed, fail_fast: true)
    expect(op.steps[2].nodes.first).to have_attributes(operation: nested_op, error: nil, fail_fast: false)
  end

  it "adds no step method names" do
    nested_op = inner
    op = operation do
      step :b
      nested nested_op
    end

    expect(op.step_method_names).to eq([:b])
  end

  it "may nest the same operation twice" do
    nested_op = inner

    expect { operation { 2.times { nested nested_op } } }.not_to raise_error
  end

  it "accepts only operation classes" do
    expect { operation { nested Object } }.to raise_error(ArgumentError, /expected an Octorail::Operation subclass/)
    expect { operation { nested :charge } }.to raise_error(ArgumentError, /got :charge/)
    expect { operation { nested Octorail::Operation } }.to raise_error(ArgumentError, /subclass/)
  end

  it "refuses to nest itself" do
    expect { operation { nested self } }.to raise_error(ArgumentError, /can't nest itself/)
  end

  it "validates options" do
    nested_op = inner

    expect { operation { nested nested_op, error: "x" } }.to raise_error(ArgumentError, /error: must be a Symbol/)
    expect { operation { nested nested_op, fail_fast: 1 } }.to raise_error(ArgumentError, /fail_fast: must be true/)
    expect { operation { nested nested_op, rescue: 1 } }.to raise_error(ArgumentError, /unknown keyword: :rescue/)
  end

  it "invalidates compiled code" do
    nested_op = inner
    op = operation { step :b }
    op.define_method(:b) { |_ctx| true }
    op.compile!

    op.nested nested_op

    expect(op).not_to be_compiled
  end
end
