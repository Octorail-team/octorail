# frozen_string_literal: true

RSpec.describe Octorail::DSL::Switches do
  def operation(&)
    Class.new(Octorail::Operation, &)
  end

  it "records a switch node with its branches" do
    op = operation do
      switch :flow_for do
        on(:admin) { step :a }
        on(:user, :guest)
      end
    end

    switch = op.steps.first
    expect(switch).to have_attributes(decider: :flow_for, name: :flow_for, type: :switch, keys: %i[admin user guest])
    expect(switch.branches.map(&:keys)).to eq([[:admin], %i[user guest]])
    expect(op.all_steps.map(&:name)).to eq([:a])
    expect(op.step_method_names).to contain_exactly(:a, :flow_for)
  end

  it "requires a block with branches" do
    expect { operation { switch :x } }.to raise_error(ArgumentError, /switch :x needs a block/)
    expect { operation { switch(:x) { nil } } }.to raise_error(ArgumentError, /switch :x has no on\(...\) branches/)
  end

  it "requires steps to be inside on(...)" do
    expect { operation { switch(:x) { step :a } } }.to raise_error(ArgumentError, /steps must be inside on/)
  end

  it "allows on only directly inside a switch" do
    expect { operation { on(:a) } }.to raise_error(ArgumentError, /only allowed directly inside a switch/)
    expect { operation { switch(:x) { on(:a) { on(:b) } } } }.to raise_error(ArgumentError, /only allowed directly/)
  end

  it "validates branch keys" do
    expect { operation { switch(:x) { on } } }.to raise_error(ArgumentError, /on needs at least one key/)
    expect { operation { switch(:x) { on("a") } } }.to raise_error(ArgumentError, /on keys must be Symbols/)
    expect { operation { switch(:x) { on(:a, :a) } } }.to raise_error(ArgumentError, /repeats a key/)
    expect { operation { switch(:x) { on(:a); on(:a) } } }.to raise_error(ArgumentError, /on :a is already a branch/) # rubocop:disable Style/Semicolon
  end

  it "rejects the same step twice in one branch, or in a branch and outside the switch" do
    expect { operation { switch(:x) { on(:a) { step :s; step :s } } } } # rubocop:disable Style/Semicolon
      .to raise_error(ArgumentError, /already declared/)

    expect do
      operation do
        switch(:x) { on(:a) { step :s } }
        step :s
      end
    end.to raise_error(ArgumentError, /step :s is already declared/)
  end

  it "rejects a keyword as the decider" do
    expect { operation { switch(:case) { on(:a) } } }.to raise_error(ArgumentError, /switch :case is a Ruby keyword/)
  end

  it "invalidates compiled code" do
    op = operation { step :a }
    op.define_method(:a) { |_ctx| true }
    op.compile!

    op.switch(:x) { op.on(:a) }

    expect(op).not_to be_compiled
  end
end
