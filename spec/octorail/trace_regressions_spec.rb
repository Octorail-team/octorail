# frozen_string_literal: true

# Regressions for bugs found by the second code audit (tracing, error locations, branches);
# each example failed before its fix.
RSpec.describe "audit regressions, round 2" do # rubocop:disable RSpec/DescribeClass
  def operation(parent = Octorail::Operation, &)
    Class.new(parent, &)
  end

  def raised_by
    yield
    nil
  rescue Exception => e # rubocop:disable Lint/RescueException
    e
  end

  def walk(nodes, &block)
    nodes&.each do |node|
      yield node
      walk(node[:nodes], &block)
    end
  end

  let(:recovering) { Class.new { def self.call(_ctx) = yield || true } }

  describe "a container left by a failure exit" do
    let(:op) do
      wrapper = recovering
      operation do
        wrap(wrapper) { switch(:kind) { on(:a) { step :fails } } }
        step :boom

        def kind(_ctx) = :a
        def fails(_ctx) = false
        def boom(ctx) = ctx[:raise] ? raise("boom") : true
      end
    end

    it "is closed when its parent closes, not when the call ends" do
      wrap = op.call_traced.trace.to_h[:nodes].first

      expect(wrap[:nodes].first).to include(type: :switch, outcome: :failed)
      expect(wrap[:nodes].first[:duration_ms]).to be <= wrap[:duration_ms]
    end

    it "is not marked raised by a later exception" do
      raised = []
      begin
        op.call_traced(raise: true)
      rescue RuntimeError => e
        walk(e.octorail_trace.to_h[:nodes]) { |node| raised << node[:name] if node[:outcome] == :raised }
      end

      expect(raised).to eq([:boom])
    end
  end

  describe "an exception a wrapper rescues" do
    let(:op) do
      operation do
        wrap(:timeout) { step :call_api }

        def timeout(_ctx)
          yield
        rescue IOError
          false
        end

        def call_api(_ctx) = raise(IOError, "timeout")
      end
    end

    it "is recorded on the step that raised it" do
      trace = op.call_traced.trace

      expect(trace.to_h[:nodes].first[:nodes].first).to include(name: :call_api, outcome: :raised, exception: "IOError")
      expect(trace.to_s).to include("! call_api (raised IOError, rescued by timeout)")
    end
  end

  describe "ctx values" do
    let(:op) do
      operation do
        wrap(:with_user) { step :load_user }

        def with_user(ctx) = yield && ctx[:user]
        def load_user(ctx) = ctx[:user] = { ssn: "123-45-6789" }
        def boom(_ctx) = raise("boom")
      end
    end

    it "never get into a trace, not even as a returned value" do
      trace = op.call_traced.trace

      expect([trace.to_s, trace.inspect, trace.to_h.inspect].join).not_to include("6789")
      expect(trace.root.children.first.value).to be(true)
    end

    it "don't stop an exception with a trace from being serialized" do
      op = operation do
        step :keep_io
        step :boom
        def keep_io(ctx) = ctx[:out] = $stdout
        def boom(_ctx) = raise("boom")
      end
      error = raised_by { op.call_traced }

      expect(Marshal.load(Marshal.dump(error)).octorail_trace.to_s).to include("! boom")
    end
  end

  describe "error locations" do
    it "name the switch that raised, not the first one with its decider" do
      op = operation do
        switch(:kind) { on(:a) { step :x } }
        switch(:kind) { on(:a) { step :y } }
        def kind(ctx) = ctx[:kinds].shift
        def x(_ctx) = true
        def y(_ctx) = true
      end
      second = op.method_nodes.grep(Octorail::Nodes::Switch).last

      expect { op.call(kinds: %i[a zzz]) }
        .to raise_error(Octorail::UnknownBranchError, /declared at #{Regexp.escape(second.location)}\z/)
    end

    it "name the step that raised, not the first one with its name" do
      op = operation do
        switch :kind do
          on(:a) { step :save }
          on(:b) { step :save }
        end
        def kind(ctx) = ctx[:kind]
        def save(_ctx, model:) = model
      end
      second = op.all_steps.last

      expect { op.call(kind: :b) }
        .to raise_error(Octorail::MissingKeyError, /declared at #{Regexp.escape(second.location)}\z/)
    end
  end

  it "rejects a step reused in another branch with another type" do
    expect do
      operation do
        switch :kind do
          on(:a) { failure :notify }
          on(:b) { step :notify }
        end
      end
    end.to raise_error(ArgumentError, /step :notify is failure :notify in another branch/)
  end

  it "rejects keywords passed to nested_call (meant as call)" do
    op = operation do
      step :a
      def a(_ctx) = true
    end

    expect { op.nested_call(id: 1) }.to raise_error(ArgumentError, /no keywords accepted/)
  end

  it "renders a switch whose decider raised without a branch" do
    op = operation do
      switch(:kind) { on(:a) }
      def kind(_ctx) = raise(ArgumentError, "no kind")
    end
    error = raised_by { op.call_traced }

    expect(error.octorail_trace.to_s).to include("switch kind (raised ArgumentError)")
    expect(error.octorail_trace.to_h[:nodes].first).not_to have_key(:branch)
  end

  describe "a separate traced call inside a step" do
    let(:inner) do
      operation do
        configure trace: :path
        step :boom
        def boom(_ctx) = raise(IOError, "down")
      end
    end

    it "keeps the inner trace under the step that made the call" do
      inner_op = inner
      op = operation do
        step :call_inner
        define_method(:call_inner) { |_ctx| inner_op.call.success? }
      end
      error = raised_by { op.call_traced }

      expect(error.octorail_trace.to_h[:nodes].first[:trace]).to include(nodes: [include(name: :boom)])
      expect(error.octorail_trace.to_s).to include("! call_inner (raised IOError)", "! boom (raised IOError)")
    end
  end

  describe "a nested operation with its own trace setting" do
    it "runs untraced inside an untraced outer operation" do
      inner_op = operation do
        configure trace: :path
        step :a
        def a(_ctx) = true
      end
      op = operation { nested inner_op }
      allow(Octorail::Trace).to receive(:new).and_call_original

      expect(op.call).to be_success
      expect(Octorail::Trace).not_to have_received(:new)
      expect(inner_op.call.trace).to be_a(Octorail::Trace)
    end
  end
end
