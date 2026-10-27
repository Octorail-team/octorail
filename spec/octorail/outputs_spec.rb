# frozen_string_literal: true

RSpec.describe "outputs" do # rubocop:disable RSpec/DescribeClass
  let(:op) do
    Class.new(Octorail::Operation) do
      output :relation, :total

      step :fetch
      step :count
      def fetch(ctx) = ctx[:relation] = %w[ann bob]
      def count(ctx, relation:) = (ctx[:tmp] = :scratch) && (ctx[:total] = relation.size)
    end
  end

  describe "result" do
    subject(:result) { op.call }

    it "has a reader per output" do
      expect(result).to have_attributes(relation: %w[ann bob], total: 2)
    end

    it "allows [] for outputs only" do
      expect(result[:total]).to eq(2)
      expect { result[:tmp] }.to raise_error(Octorail::UnknownOutputError, /:tmp is not an output.*result\.ctx\[:tmp\]/)
    end

    it "still refuses Result fields in []" do
      expect { result[:error] }.to raise_error(Octorail::ReservedKeyError)
    end

    it "keeps the full ctx available" do
      expect(result.ctx[:tmp]).to eq(:scratch)
    end

    it "exposes only outputs and Result fields to pattern matching" do
      expect(result.deconstruct_keys(nil).keys).to contain_exactly(
        :success, :terminus, :error, :errors, :failed_step, :relation, :total
      )
      expect((result in { success: true, total: 2 })).to be(true)
    end

    it "raises for a key outside the outputs in pattern matching, like []" do
      expect { result in { success: true, tmp: } }
        .to raise_error(Octorail::UnknownOutputError, /:tmp is not an output \(outputs: :relation, :total\)/)
    end

    it "does not match a declared output that is absent on failure" do
      failing = Class.new(Octorail::Operation) do
        output :user
        step :find
        def find(_ctx) = false
      end

      expect((failing.call in { user: })).to be(false)
    end

    it "pattern matches even when a hidden ctx key is named like a Result field" do
      op.class_eval { def fetch(ctx) = (ctx[:error] = :internal) && (ctx[:relation] = []) }

      expect((op.call in { success: true, total: 0 })).to be(true)
    end

    it "is an instance of the operation's own Result subclass" do
      expect(result).to be_a(Octorail::Result)
      expect(result.class).to equal(op::OctorailResult)
    end
  end

  describe "success check" do
    def op_setting(*keys)
      Class.new(Octorail::Operation) do
        output :model
        step :run
        define_method(:run) { |ctx| keys.each { |key| ctx[key] = nil } || true }
      end
    end

    it "raises when the operation succeeds without an output" do
      expect { op_setting(:other).call(params: 1) }.to raise_error(
        Octorail::MissingOutputError, /succeeded without setting output :model \(ctx keys: :params, :other\)/
      )
    end

    it "accepts an output set to nil" do
      expect(op_setting(:model).call.model).to be_nil
    end

    it "does not check outputs on failure" do
      failing = Class.new(Octorail::Operation) do
        output :model
        step :run, error: :invalid
        def run(_ctx) = false
      end

      expect(failing.call).to have_attributes(error: :invalid, model: nil)
    end
  end

  it "is inherited and extended by subclasses" do
    child = Class.new(op) do
      output :page
      pass :paginate
      def paginate(ctx) = ctx[:page] = 1
    end

    expect(child.call).to have_attributes(relation: %w[ann bob], total: 2, page: 1)
  end

  it "rejects outputs that collide with Result methods" do
    %i[ctx hash to_h success? inspect].each do |name|
      expect { Class.new(Octorail::Operation) { output name } }
        .to raise_error(ArgumentError, /collides with a Result field or method/)
    end
  end

  it "leaves operations without outputs on the base Result" do
    plain = Class.new(Octorail::Operation) do
      step :run
      def run(ctx) = ctx[:anything] = 1
    end

    expect(plain.call.class).to equal(Octorail::Result)
    expect(plain.call[:anything]).to eq(1)
  end

  it "generates output checks before success" do
    expect(op.to_ruby).to include(<<~RUBY.gsub(/^/, "  "))
      __octorail_missing_output(:relation, ctx) unless ctx.key?(:relation)
      __octorail_missing_output(:total, ctx) unless ctx.key?(:total)
      OctorailResult.new(:success, ctx)
    RUBY
  end
end
