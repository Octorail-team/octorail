# frozen_string_literal: true

RSpec.describe Octorail::Error do
  let(:op) do
    Class.new(Octorail::Operation) do
      step :a
      def a(_ctx, params:) = params
    end
  end

  it "is not a StandardError, so a bare rescue doesn't swallow it" do
    expect(described_class.ancestors).not_to include(StandardError)
    expect do
      op.call
    rescue => e # rubocop:disable Style/RescueStandardError
      e
    end.to raise_error(Octorail::MissingKeyError)
  end

  it "flies through a wrapper that rescues StandardError" do
    wrapper = Class.new do
      def self.call(_ctx)
        yield
      rescue StandardError
        false
      end
    end
    op = Class.new(Octorail::Operation) do
      wrap(wrapper) { step :a }
      def a(_ctx, params:) = params
    end

    expect { op.call }.to raise_error(Octorail::MissingKeyError)
  end

  it "is still caught by rescuing it explicitly" do
    caught =
      begin
        op.call
      rescue described_class => e
        e
      end

    expect(caught).to be_a(Octorail::MissingKeyError)
  end
end
