# frozen_string_literal: true

RSpec.describe "nested cycles" do # rubocop:disable RSpec/DescribeClass
  def operation(parent = Octorail::Operation, &)
    Class.new(parent, &).tap do |op|
      op.define_method(:a) { |_ctx| true }
    end
  end

  it "raises CompileError for a two-operation cycle, naming the path and the closing declaration" do
    stub_const("CycleA", operation { step :a })
    line = __LINE__ + 1
    stub_const("CycleB", operation { nested CycleA })
    CycleA.nested CycleB

    expect { CycleA.compile! }.to raise_error(
      Octorail::CompileError,
      /CycleA: nested operations form a cycle: CycleA → CycleB → CycleA\n  declared at .*:#{line}\z/
    )
  end

  it "finds a cycle further down the graph" do
    stub_const("CycleB", operation { step :a })
    stub_const("CycleC", operation { nested CycleB })
    CycleB.nested CycleC
    top = operation { nested CycleB }

    expect { top.compile! }.to raise_error(Octorail::CompileError, /cycle: CycleB → CycleC → CycleB/)
  end

  it "finds a cycle through a wrap and through inheritance" do
    stub_const("CycleParent", operation { step :a })
    stub_const("CycleChild", operation(CycleParent))
    stub_const("CycleShared", operation { nested CycleChild })
    CycleParent.class_eval { wrap(->(_ctx, &blk) { blk.call }) { nested CycleShared } }

    expect { CycleChild.compile! }
      .to raise_error(Octorail::CompileError, /cycle: CycleChild → CycleShared → CycleChild/)
  end

  it "allows the same operation nested several times without a cycle" do
    shared = operation { step :a }
    middle = operation { nested shared }
    top = operation do
      nested shared
      nested middle
    end

    expect(top.call).to be_success
  end

  it "is caught by compile_all!" do
    root = Class.new(Octorail::Operation)
    stub_const("CycleA", operation(root) { step :a })
    stub_const("CycleB", operation(root) { nested CycleA })
    CycleA.nested CycleB

    expect { Octorail.compile_all!(root) }.to raise_error(Octorail::CompileError, /form a cycle/)
  end
end
