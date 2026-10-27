# frozen_string_literal: true

RSpec.describe "declaration locations" do # rubocop:disable RSpec/DescribeClass
  let(:file) { "spec/octorail/locations_spec.rb" }

  it "records where each node was declared" do
    inner = Class.new(Octorail::Operation) { step :a }
    line = __LINE__ + 2
    op = Class.new(Octorail::Operation) do
      step :a
      wrap(:tx) { step :b }
      nested inner
    end

    expect(op.steps.map(&:location)).to eq(["#{file}:#{line}", "#{file}:#{line + 1}", "#{file}:#{line + 2}"])
    expect(op.steps[1].nodes.first.location).to eq("#{file}:#{line + 1}")
  end

  it "shows it in CompileError for a missing method" do
    line = __LINE__ + 1
    op = Class.new(Octorail::Operation) { step :missing }

    expect { op.compile! }.to raise_error(Octorail::CompileError, /\n  declared at #{file}:#{line}\z/)
  end

  it "shows it in CompileError for a missing wrapper method" do
    line = __LINE__ + 1
    op = Class.new(Octorail::Operation) { wrap(:tx) { step :a } }
    op.define_method(:a) { |_ctx| true }

    expect { op.compile! }.to raise_error(Octorail::CompileError, /wrap :tx .*\n  declared at #{file}:#{line}\z/)
  end

  it "shows it in CompileError for an unsupported signature" do
    line = __LINE__ + 1
    op = Class.new(Octorail::Operation) { step :a }
    op.define_method(:a) { |_ctx, **| true }

    expect { op.compile! }.to raise_error(Octorail::CompileError, /uses \*\*.*\n  declared at #{file}:#{line}\z/)
  end

  it "shows it in MissingKeyError" do
    line = __LINE__ + 1
    op = Class.new(Octorail::Operation) { step :a }
    op.define_method(:a) { |_ctx, params:| params }

    expect { op.call }.to raise_error(Octorail::MissingKeyError, /requires :params.*\n  declared at #{file}:#{line}\z/)
  end

  it "points to the parent's file for an inherited step" do
    line = __LINE__ + 1
    parent = Class.new(Octorail::Operation) { step :authorize }
    child = Class.new(parent) { step :save }
    child.define_method(:save) { |_ctx| true }

    expect { child.compile! }.to raise_error(Octorail::CompileError, /:authorize .*declared at #{file}:#{line}\z/m)
  end

  # Evaluated under fake file names, as if a macro module and an operation lived in an app.
  it "adds the class body line when a macro declared the step" do
    namespace = Module.new
    # rubocop:disable Style/EvalWithLocation
    namespace.module_eval(<<~RUBY, File.join(Dir.pwd, "app/macros.rb"), 1)
      module Macros
        def model(*)
          step :find_model
        end
      end
    RUBY
    namespace.module_eval(<<~RUBY, File.join(Dir.pwd, "app/operations/update.rb"), 1)
      class Update < Octorail::Operation
        extend Macros

        model :user
      end
    RUBY
    # rubocop:enable Style/EvalWithLocation

    expect(namespace::Update.steps.first.location).to eq("app/macros.rb:3 (via app/operations/update.rb:4)")
  end
end
