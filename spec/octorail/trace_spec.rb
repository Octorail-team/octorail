# frozen_string_literal: true

RSpec.describe Octorail::Trace do
  after { Octorail.config.trace = :off }

  # Steps return true unless named in ctx[:fail]; the switch decider returns ctx[:role].
  def operation(&block)
    Class.new(Octorail::Operation) do
      class_eval(&block)
      define_method(:flow_for) { |_ctx, role:| role } unless method_defined?(:flow_for)
      all_steps.grep(Octorail::Nodes::Step).map(&:name).uniq.each do |name|
        next if method_defined?(name)

        define_method(name) { |ctx| !ctx.fetch(:fail, []).include?(name) }
      end
    end
  end

  let(:wrapper) { Class.new { def self.call(_ctx) = yield }.tap { |w| stub_const("Transaction", w) } }
  let(:inner) { operation { step :charge, error: :declined }.tap { |op| stub_const("Billing::Charge", op) } }

  let(:op) do
    wrapper
    inner
    operation do
      step :validate
      switch :flow_for do
        on(:admin) { step :grant }
        on(:user)
      end
      wrap Transaction do
        nested Billing::Charge
        failure :charge_wallet, recover: true
      end
      pass :notify
      failure :log
    end
  end

  def names(nodes) = nodes.map { |node| [node[:type], node[:name], node[:outcome]] }

  describe "call_traced" do
    it "records the path into result.trace, through wraps, branches and nested operations" do
      trace = op.call_traced(role: :admin, fail: %i[charge charge_wallet]).trace.to_h

      expect(trace).to include(operation: op.inspect, level: :profile, terminus: :failure,
                               error: :declined, failed_step: :charge)
      expect(names(trace[:nodes])).to eq(
        [%i[step validate success], %i[switch flow_for success], [:wrap, "Transaction", :failure],
         %i[failure log ran]]
      )
      expect(trace[:nodes][1]).to include(branch: :admin)
    end

    it "goes inside wraps and nested operations" do
      wrap = op.call_traced(role: :admin, fail: %i[charge charge_wallet]).trace.to_h[:nodes][2]

      expect(names(wrap[:nodes]))
        .to eq([[:nested, "Billing::Charge", :failure], %i[recover charge_wallet not_recovered]])
      expect(names(wrap[:nodes][0][:nodes])).to eq([%i[step charge failure]])
    end

    it "records durations at :profile" do
      trace = op.call_traced(role: :user).trace

      expect(trace.duration).to be > 0
      expect(trace.to_h[:nodes]).to all(include(:duration_ms))
    end

    it "renders a tree" do
      rendered = op.call_traced(role: :admin, fail: [:charge]).trace.to_s.gsub(/  \d+\.\d+ ms/, "")

      expect(rendered).to eq(<<~TEXT)
        #{op.inspect}
        ├── ✓ validate
        ├── switch flow_for → :admin
        │   └── ✓ grant
        ├── wrap Transaction → true
        │   ├── ✗ nested Billing::Charge
        │   │   └── ✗ charge
        │   └── ↺ recover charge_wallet (recovered)
        ├── · notify
        └── success
      TEXT
    end

    it "marks a node the call left by a failure exit" do
      op = operation do
        switch(:flow_for) { on(:admin) { step :grant } }
      end

      expect(op.call_traced(role: :admin, fail: [:grant]).trace.to_h[:nodes].first)
        .to include(type: :switch, outcome: :failed)
    end

    it "never holds ctx values" do
      trace = op.call_traced(role: :admin, secret: "card 4242", fail: [:charge]).trace

      expect(trace.to_s + trace.to_h.inspect).not_to include("4242")
    end

    it "installs the traced variant only when needed" do
      op.call(role: :user)

      expect(op.private_method_defined?(:__octorail_traced) || op.method_defined?(:__octorail_traced)).to be(false)
      op.call_traced(role: :user)
      expect(op.method_defined?(:__octorail_traced)).to be(true)
    end
  end

  describe "the trace setting" do
    it "makes a plain call traced, at :path without durations" do
      op.configure trace: :path
      trace = op.call(role: :user).trace

      expect(trace.level).to eq(:path)
      expect(trace.duration).to be_nil
      expect(trace.to_h[:nodes].first).not_to include(:duration_ms)
    end

    it "leaves the plain code untouched when :off" do
      expect(op.call(role: :user).trace).to be_nil
      expect(op.to_ruby).not_to include("__t")
    end

    it "traces nested operations through, whatever their own setting" do
      inner.configure trace: :off
      op.configure trace: :path

      expect(names(op.call(role: :user).trace.to_h[:nodes][2][:nodes][0][:nodes])).to eq([%i[step charge success]])
      expect(inner.call.trace).to be_nil
    end
  end

  describe "exceptions" do
    let(:failing) do
      inner
      operation do
        step :validate
        nested Billing::Charge
      end
    end

    before { inner.define_method(:charge) { |_ctx| raise IOError, "gateway timeout" } }

    it "attaches the trace to the exception and re-raises it unchanged" do
      error = nil
      begin
        failing.call_traced
      rescue IOError => e
        error = e
      end

      expect(error.message).to eq("gateway timeout")
      expect(error.octorail_trace.to_h).to include(exception: "IOError")
      expect(names(error.octorail_trace.to_h[:nodes]))
        .to eq([%i[step validate success], [:nested, "Billing::Charge", :raised]])
      expect(error.octorail_trace.to_s).to include("! charge (raised IOError)", "└── raised IOError: gateway timeout")
    end

    it "keeps the original backtrace" do
      error = failing.call_traced rescue $! # rubocop:disable Style/RescueModifier, Style/SpecialGlobalVars

      expect(error.backtrace.first).to include("trace_spec.rb")
    end

    it "skips a frozen exception" do
      inner.define_method(:charge) { |_ctx| raise IOError.new("frozen").freeze }

      expect { failing.call_traced }.to raise_error(IOError, "frozen")
    end
  end

  it "passes the trace node to a stubbed nested_call" do
    allow(inner).to receive(:nested_call) { |ctx, _trace| Octorail::Result.new(:failure, ctx, :stubbed, :charge) }

    trace = op.call_traced(role: :user, fail: [:charge_wallet]).trace

    expect(trace).to have_attributes(error: :stubbed, failed_step: :charge)
    expect(inner).to have_received(:nested_call).with(Hash, Octorail::Trace::Node)
  end
end
