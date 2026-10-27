# frozen_string_literal: true

RSpec.describe Octorail::Config do
  after { Octorail.config.trace = :off }

  def operation(parent = Octorail::Operation, &block)
    Class.new(parent) do
      class_eval(&block) if block
      def a(_ctx) = true
    end
  end

  it "has defaults" do
    expect(Octorail.config).to have_attributes(trace: :off)
  end

  it "is set in a configure block" do
    Octorail.configure { |config| config.trace = :path }

    expect(Octorail.config.trace).to eq(:path)
  end

  it "rejects unknown values" do
    expect { Octorail.config.trace = true }
      .to raise_error(ArgumentError, /trace must be one of :off, :path, :profile, got true/)
    expect { Octorail.configure { |config| config.trcae = :path } }.to raise_error(NoMethodError, /trcae=/)
  end

  describe "an operation's configure" do
    it "overrides the global value, and is inherited" do
      parent = operation { configure trace: :profile }
      child = operation(parent)
      Octorail.config.trace = :path

      expect([parent.setting(:trace), child.setting(:trace)]).to eq(%i[profile profile])
      expect(operation.setting(:trace)).to eq(:path)
    end

    it "is allowed in an abstract base" do
      base = operation do
        abstract!
        configure trace: :path
      end

      expect(operation(base).setting(:trace)).to eq(:path)
    end

    it "rejects unknown settings and values" do
      expect { operation { configure trcae: :path } }.to raise_error(ArgumentError, /unknown setting :trcae/)
      expect { operation { configure trace: :all } }.to raise_error(ArgumentError, /trace must be one of/)
    end
  end

  it "recompiles compiled operations when a setting changes" do
    op = operation { step :a }
    op.call

    Octorail.config.trace = :path

    expect(op).not_to be_compiled
    expect(op.call.trace).to be_a(Octorail::Trace)
  end
end
