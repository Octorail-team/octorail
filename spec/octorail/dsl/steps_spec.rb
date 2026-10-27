# frozen_string_literal: true

RSpec.describe Octorail::DSL::Steps do
  def operation(parent = Octorail::Operation, &)
    Class.new(parent, &)
  end

  describe "step / pass / failure" do
    it "records steps in declaration order with defaults" do
      op = operation do
        step :validate
        pass :notify
        failure :log
      end

      expect(op.steps.map { |s| [s.type, s.name] }).to eq([%i[step validate], %i[pass notify], %i[failure log]])
      expect(op.steps.first).to have_attributes(error: nil, fail_fast: false)
    end

    it "records step options" do
      op = operation do
        step :find, error: :not_found, fail_fast: true
      end

      expect(op.steps.first).to have_attributes(error: :not_found, fail_fast: true)
    end

    it "requires fail_fast: to be a boolean" do
      expect { operation { step :x, fail_fast: "yes" } }.to raise_error(ArgumentError, /must be true or false/)
    end

    it "has no pass_fast option" do
      expect { operation { step :x, pass_fast: true } }.to raise_error(ArgumentError, /unknown options \[:pass_fast\]/)
    end

    it "rejects options a step type doesn't support" do
      expect { operation { pass :x, error: :nope } }.to raise_error(ArgumentError, /pass :x: unknown options/)
      expect { operation { failure :x, error: :e } }.to raise_error(ArgumentError, /unknown options \[:error\]/)
      expect { operation { step :x, recover: true } }.to raise_error(ArgumentError, /unknown options \[:recover\]/)
      expect { operation { step :x, retry: 3 } }.to raise_error(ArgumentError, /unknown options \[:retry\]/)
    end

    it "requires error: to be a Symbol" do
      expect { operation { step :x, error: "not_found" } }.to raise_error(ArgumentError, /error: must be a Symbol/)
    end

    it "rejects names that are not Symbol method names" do
      expect { operation { step "validate" } }.to raise_error(ArgumentError, /must be a Symbol/)
      expect { operation { step :"drop table" } }.to raise_error(ArgumentError, /must be a Symbol/)
      expect { operation { step :valid? } }.not_to raise_error
    end

    it "rejects duplicate step names" do
      expect do
        operation do
          step :validate
          failure :validate
        end
      end.to raise_error(ArgumentError, /:validate is already declared/)
    end
  end

  describe "inheritance" do
    let(:parent) do
      operation do
        output :model
        step :validate
        step :persist
      end
    end

    it "appends subclass steps after the parent's" do
      child = operation(parent) { step :audit }

      expect(child.steps.map(&:name)).to eq(%i[validate persist audit])
      expect(parent.steps.map(&:name)).to eq(%i[validate persist])
    end

    it "inherits outputs and adds its own" do
      child = operation(parent) { output :audit_log }

      expect(child.outputs).to eq(%i[model audit_log])
    end

    it "sees steps added to the parent after the subclass was defined" do
      child = operation(parent) { step :audit }
      parent.step :notify

      expect(child.steps.map(&:name)).to eq(%i[validate persist notify audit])
    end

    it "rejects redeclaring a parent's step" do
      expect { operation(parent) { step :validate } }.to raise_error(ArgumentError, /already declared/)
    end
  end
end
