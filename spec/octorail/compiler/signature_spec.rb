# frozen_string_literal: true

RSpec.describe Octorail::Compiler::Signature do
  def operation(&)
    Class.new(Octorail::Operation) do
      step :run
      class_eval(&)
    end
  end

  describe "(ctx)" do
    it "calls the step with ctx only" do
      op = operation { def run(ctx) = ctx[:seen] = true }

      expect(op.to_ruby).to include("unless run(ctx)")
      expect(op.call[:seen]).to be(true)
    end
  end

  describe "required keywords" do
    let(:op) { operation { def run(ctx, params:, user:) = ctx[:got] = [params, user] } }

    it "passes them from ctx" do
      expect(op.call(params: 1, user: 2)[:got]).to eq([1, 2])
    end

    it "passes nil when the key is present with nil" do
      expect(op.call(params: nil, user: 2)[:got]).to eq([nil, 2])
    end

    it "raises MissingKeyError naming the step, the key and the ctx keys" do
      expect { op.call(params: 1, other: 3) }.to raise_error(
        Octorail::MissingKeyError, /step :run requires :user, but ctx has no :user \(ctx keys: :params, :other\)/
      )
    end
  end

  describe "optional keywords" do
    it "uses the method default when the key is absent" do
      op = operation { def run(ctx, list: []) = ctx[:got] = list }

      expect(op.call[:got]).to eq([])
      expect(op.call(list: [1])[:got]).to eq([1])
    end

    it "passes nil when the key is present with nil" do
      op = operation { def run(ctx, list: []) = ctx[:got] = list }

      expect(op.call(list: nil)[:got]).to be_nil
    end

    it "branches on every combination of two optional keys" do
      op = operation { def run(ctx, alpha: :da, beta: :db) = ctx[:got] = [alpha, beta] }

      expect([op.call, op.call(alpha: 1), op.call(beta: 2), op.call(alpha: 1, beta: 2)].map { |r| r[:got] })
        .to eq([%i[da db], [1, :db], [:da, 2], [1, 2]])
    end

    it "uses ctx.slice for three or more optional keys" do
      op = operation { def run(ctx, alpha: :da, beta: :db, gamma: :dc) = ctx[:got] = [alpha, beta, gamma] }

      expect(op.to_ruby).to include("**ctx.slice(:alpha, :beta, :gamma)")
      expect(op.call(beta: 2)[:got]).to eq([:da, 2, :dc])
    end

    it "mixes required and optional keywords" do
      op = operation { def run(ctx, params:, mailer: :real) = ctx[:got] = [params, mailer] }

      expect(op.call(params: 1)[:got]).to eq([1, :real])
      expect(op.call(params: 1, mailer: :fake)[:got]).to eq([1, :fake])
      expect { op.call(mailer: :fake) }.to raise_error(Octorail::MissingKeyError, /requires :params/)
    end
  end

  describe "generated code for optional keywords" do
    let(:op) do
      Class.new(Octorail::Operation) do
        step :validate
        pass :tag
        failure :log
        def validate(ctx, params:, strict: false) = ctx && params && strict
        def tag(ctx, source: :web, locale: :en) = ctx && source && locale
        def log(ctx, logger: nil) = ctx && logger
      end
    end

    let(:expected) { <<~RUBY }
      def __octorail_call(ctx)
        ok =
          if ctx.key?(:strict)
            validate(ctx, params: ctx.fetch(:params) { __octorail_missing_key(0, :params, ctx, :validate) }, strict: ctx[:strict])
          else
            validate(ctx, params: ctx.fetch(:params) { __octorail_missing_key(0, :params, ctx, :validate) })
          end
        unless ok
          if ctx.key?(:logger)
            log(ctx, logger: ctx[:logger])
          else
            log(ctx)
          end
          return ::Octorail::Result.new(:failure, ctx, :failure, :validate)
        end
        if ctx.key?(:source)
          if ctx.key?(:locale)
            tag(ctx, source: ctx[:source], locale: ctx[:locale])
          else
            tag(ctx, source: ctx[:source])
          end
        else
          if ctx.key?(:locale)
            tag(ctx, locale: ctx[:locale])
          else
            tag(ctx)
          end
        end
        ::Octorail::Result.new(:success, ctx)
      rescue FrozenError => e
        __octorail_frozen!(e)
      end
    RUBY

    it "uses multiline if/else instead of ternaries" do
      expect(op.to_ruby).to eq(expected)
    end
  end

  it "allows a block parameter" do
    op = operation { def run(ctx, &) = ctx[:ok] = true }

    expect(op.call[:ok]).to be(true)
  end

  describe "rejected signatures" do
    {
      "def run(ctx, **); end" => /uses \*\* in its signature/,
      "def run(ctx, params:, **opts); end" => /uses \*\* in its signature/,
      "def run; end" => /must take ctx as its only positional argument/,
      "def run(ctx, extra); end" => /only positional argument/,
      "def run(ctx = {}); end" => /only positional argument/,
      "def run(*args); end" => /only positional argument/,
      "def run(...); end" => /only positional argument/
    }.each do |definition, message|
      it "rejects `#{definition}`" do
        op = operation { class_eval(definition) }

        expect { op.call }.to raise_error(Octorail::CompileError, message)
      end
    end
  end
end
