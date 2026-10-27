# frozen_string_literal: true

RSpec.describe Octorail::DSL::Outputs do
  def operation(parent = Octorail::Operation, &)
    Class.new(parent, &)
  end

  describe "output" do
    it "records outputs without duplicates" do
      op = operation do
        output :model, :total
        output :model
      end

      expect(op.outputs).to eq(%i[model total])
    end

    it "rejects Result field names" do
      expect { operation { output :errors } }.to raise_error(ArgumentError, /collides with a Result field/)
    end
  end
end
