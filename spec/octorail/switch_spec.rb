# frozen_string_literal: true

RSpec.describe "switch" do # rubocop:disable RSpec/DescribeClass
  # Steps append to ctx[:trace] and fail when named in ctx[:fail]; the decider returns ctx[:role].
  def operation(parent = Octorail::Operation, &block)
    Class.new(parent) do
      class_eval(&block) if block
      define_method(:flow_for) { |_ctx, role:| role } unless method_defined?(:flow_for)
      all_steps.grep(Octorail::Nodes::Step).map(&:name).uniq.each { |name| define_traced(name) }
    end
  end

  before do
    Octorail::Operation.define_singleton_method(:define_traced) do |name|
      return if method_defined?(name) || private_method_defined?(name)

      define_method(name) { |ctx| (ctx[:trace] << name) && !ctx[:fail].include?(name) }
    end
  end

  after { Octorail::Operation.singleton_class.remove_method(:define_traced) }

  def run(operation, role:, fail: []) = operation.call(role:, fail:, trace: [])

  let(:op) do
    operation do
      step :validate
      switch :flow_for do
        on(:admin) do
          step :grant_all, error: :grant_failed
          failure :revoke
        end
        on(:user, :member) { step :check_quota }
        on(:guest)
      end
      step :save
      failure :log
    end
  end

  it "runs the branch picked by the decider, then the common track" do
    expect(run(op, role: :admin)[:trace]).to eq(%i[validate grant_all save])
    expect(run(op, role: :member)[:trace]).to eq(%i[validate check_quota save])
  end

  it "does nothing for a branch without a block" do
    expect(run(op, role: :guest)).to be_success
    expect(run(op, role: :guest)[:trace]).to eq(%i[validate save])
  end

  it "runs the failure steps inside the branch, then the ones after the switch" do
    result = run(op, role: :admin, fail: [:grant_all])

    expect(result[:trace]).to eq(%i[validate grant_all revoke log])
    expect(result).to have_attributes(terminus: :failure, error: :grant_failed, failed_step: :grant_all)
  end

  it "skips both failure tracks on fail_fast inside a branch" do
    op = operation do
      switch(:flow_for) { on(:admin) { step :grant_all, fail_fast: true } }
      failure :log
    end

    expect(run(op, role: :admin, fail: [:grant_all])).to have_attributes(terminus: :fail_fast)
    expect(run(op, role: :admin, fail: [:grant_all])[:trace]).to eq([:grant_all])
  end

  it "raises UnknownBranchError for a value without a branch, naming the branches and the declaration" do
    line = __LINE__ + 1
    op = operation { switch(:flow_for) { on(:admin, :user) } }

    expect { run(op, role: :moderator) }.to raise_error(
      Octorail::UnknownBranchError,
      /switch :flow_for returned :moderator, branches: :admin, :user\n  declared at .*:#{line}\z/
    )
  end

  it "reads the decider's kwargs from ctx like a step" do
    op = operation { switch(:flow_for) { on(:admin) } }

    expect { op.call }.to raise_error(Octorail::MissingKeyError, /switch :flow_for requires :role/)
  end

  it "allows the same step in different branches" do
    op = operation do
      switch :flow_for do
        on(:admin) { step :save; step :audit } # rubocop:disable Style/Semicolon
        on(:user) { step :save; step :notify } # rubocop:disable Style/Semicolon
      end
    end

    expect(run(op, role: :user)[:trace]).to eq(%i[save notify])
  end

  it "runs a nested operation and a wrap inside a branch" do
    inner = operation { step :charge }
    op = operation do
      switch :flow_for do
        on(:admin) { nested inner }
        on(:user) { wrap(:within) { step :reserve } }
      end
      def within(ctx) = (ctx[:trace] << :begin) && yield
    end

    expect(run(op, role: :admin)[:trace]).to eq([:charge])
    expect(run(op, role: :user, fail: [:reserve])).to have_attributes(error: :failure, failed_step: :reserve)
    expect(run(op, role: :user)[:trace]).to eq(%i[begin reserve])
  end

  it "fails a surrounding wrap from inside a branch" do
    op = operation do
      wrap :within do
        switch(:flow_for) { on(:admin) { step :grant_all } }
      end
      failure :log
      def within(ctx) = yield || ((ctx[:trace] << :rollback) && false)
    end

    expect(run(op, role: :admin, fail: [:grant_all])[:trace]).to eq(%i[grant_all rollback log])
  end

  it "supports a switch inside a branch" do
    op = operation do
      switch :flow_for do
        on(:admin) do
          switch(:plan_for) { on(:pro) { step :pro_feature } }
        end
      end
      def plan_for(_ctx, plan:) = plan
    end

    expect(op.call(role: :admin, plan: :pro, fail: [], trace: [])[:trace]).to eq([:pro_feature])
  end

  it "inherits a switch and recompiles when the decider is redefined" do
    child = operation(op)
    expect(run(child, role: :admin)[:trace]).to eq(%i[validate grant_all save])

    op.class_eval { def flow_for(_ctx, role:) = role == :admin ? :user : role }

    expect(run(child, role: :admin)[:trace]).to eq(%i[validate check_quota save])
  end

  it "raises CompileError when the decider method is missing" do
    op = Class.new(Octorail::Operation) { switch(:pick) { on(:a) } }

    expect { op.compile! }.to raise_error(Octorail::CompileError, /switch :pick has no instance method #pick/)
  end

  describe "#to_ruby" do
    let(:expected) { <<~RUBY }
      def __octorail_call(ctx)
        case __s1 = flow_for(ctx, role: ctx.fetch(:role) { __octorail_missing_key(0, :role, ctx, :flow_for) })
        when :admin
          unless grant_all(ctx)
            return ::Octorail::Result.new(:failure, ctx, :failure, :grant_all)
          end
        when :guest
        else
          __octorail_unknown_branch(0, __s1)
        end
        ::Octorail::Result.new(:success, ctx)
      rescue FrozenError => e
        __octorail_frozen!(e)
      end
    RUBY

    it "compiles to a plain case" do
      op = operation do
        switch :flow_for do
          on(:admin) { step :grant_all }
          on(:guest)
        end
      end

      expect(op.to_ruby).to eq(expected)
    end
  end
end
