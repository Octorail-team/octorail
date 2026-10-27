# frozen_string_literal: true

RSpec.describe Octorail::Compiler::Code do
  subject(:code) { described_class.new }

  it "indents nested blocks and closes them with end" do
    code.block("def call(ctx)") do
      code.block("unless ok") { code.line("return 1") }
      code.line("2")
    end

    expect(code.to_s).to eq(<<~RUBY)
      def call(ctx)
        unless ok
          return 1
        end
        2
      end
    RUBY
  end

  it "builds if/else from two callables" do
    code.if_else("a", -> { code.line("1") }, -> { code.line("2") })

    expect(code.to_s).to eq("if a\n  1\nelse\n  2\nend\n")
  end

  it "restores indentation when a block raises" do
    expect { code.indented { raise "boom" } }.to raise_error("boom")
    expect(code.line("x").to_s).to eq("x\n")
  end
end
