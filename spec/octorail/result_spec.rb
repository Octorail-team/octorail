# frozen_string_literal: true

RSpec.describe Octorail::Result do
  def result(terminus, ctx = {}, error: nil, failed_step: nil)
    described_class.new(terminus, ctx, error, failed_step)
  end

  describe "#success? / #failure?" do
    it "treats only :success as success" do
      expect(result(:success)).to be_success
      expect(result(:success)).not_to be_failure
    end

    it "treats :failure and :fail_fast as failure" do
      expect(result(:failure)).to be_failure
      expect(result(:fail_fast)).to be_failure
    end
  end

  it "defaults error and failed_step to nil" do
    expect(result(:success)).to have_attributes(error: nil, failed_step: nil)
  end

  describe "#errors" do
    it "reads ctx[:errors] on failure" do
      expect(result(:failure, { errors: { email: ["is invalid"] } }).errors).to eq(email: ["is invalid"])
    end

    it "is nil on success even if ctx has :errors" do
      expect(result(:success, { errors: :leftover }).errors).to be_nil
    end
  end

  describe "#[]" do
    it "reads any ctx key" do
      expect(result(:success, { model: :user, relation: :users })[:relation]).to eq(:users)
    end

    it "returns nil for a missing key" do
      expect(result(:success)[:model]).to be_nil
    end

    it "refuses Result fields and points to the reader" do
      expect { result(:failure)[:error] }.to raise_error(Octorail::ReservedKeyError, /result\.error/)
      expect { result(:success)[:success] }.to raise_error(Octorail::ReservedKeyError, /result\.success\?/)
    end
  end

  describe "pattern matching" do
    it "matches on success and ctx keys" do
      matched =
        case result(:success, { model: :user })
        in { success: true, model: } then model
        end

      expect(matched).to eq(:user)
    end

    it "matches on error type and errors" do
      res = result(:failure, { errors: ["boom"] }, error: :invalid, failed_step: :validate)

      matched =
        case res
        in { error: :not_found } then :not_found
        in { error: :invalid, errors:, failed_step: } then [errors, failed_step]
        end

      expect(matched).to eq([["boom"], :validate])
    end

    it "does not match a key that is absent from ctx" do
      expect((result(:success) in { model: })).to be(false)
    end

    it "deconstructs everything when keys are nil" do
      expect(result(:success, { model: :user }).deconstruct_keys(nil)).to eq(
        model: :user, success: true, terminus: :success, error: nil, errors: nil, failed_step: nil
      )
    end

    it "raises when ctx holds a reserved key" do
      expect { result(:success, { error: :mine }) in { success: true } }
        .to raise_error(Octorail::ReservedKeyError, /ctx keys :error collide/)
    end
  end

  describe "value object behaviour" do
    it "compares by fields" do
      one = result(:success, { a: 1 })
      same = result(:success, { a: 1 })

      expect(one).to eq(same)
      expect(one.hash).to eq(same.hash)
      expect(one).not_to eq(result(:failure, { a: 1 }))
    end

    it "converts to a hash of its fields" do
      expect(result(:failure, {}, error: :e, failed_step: :s).to_h)
        .to eq(terminus: :failure, ctx: {}, error: :e, failed_step: :s)
    end

    it "has no writers" do
      expect(result(:success)).not_to respond_to(:terminus=, :ctx=, :error=, :failed_step=)
    end

    it "inspects readably" do
      expect(result(:success, { a: 1 }).inspect)
        .to eq("#<Octorail::Result terminus=:success error=nil failed_step=nil ctx=#{{ a: 1 }.inspect}>")
    end
  end

  it "does not raise for reserved ctx keys unless pattern matched" do
    expect(result(:success, { terminus: :x, model: :user })[:model]).to eq(:user)
  end
end
