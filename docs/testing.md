# Testing

An operation is a class with a `call` that takes keyword arguments and returns a
[result](result.md). Its steps are plain instance methods. This page shows how to test the whole
operation and its single steps, how to fake a nested operation, and how to read a failure.

The examples use these operations:

```ruby
module Billing
  class Charge < Octorail::Operation
    step :charge, error: :declined
    def charge(ctx, order:, gateway: PaymentGateway) = ctx[:payment_id] = gateway.charge(order[:total])
  end
end

class PaymentGateway
  def self.charge(_amount) = "pay_#{rand(1000)}"
end

module Orders
  class Place < Octorail::Operation
    step :validate, error: :invalid
    step :build_order
    nested Billing::Charge
    failure :release_stock

    def validate(_ctx, params:) = params[:items].to_a.any?
    def build_order(ctx, params:) = ctx[:order] = { items: params[:items], total: params[:items].size * 10 }
    def release_stock(ctx, failed_step:) = ctx[:released_after] = failed_step
  end
end
```

## The whole operation

Call the operation with input and check the result: `success?`, `terminus`, `error`, `failed_step`, and ctx keys through `[]`.

```ruby
RSpec.describe Orders::Place do
  it "places an order" do
    result = described_class.call(params: { items: %w[book pen] })

    expect(result).to be_success
    expect(result[:order]).to eq(items: %w[book pen], total: 20)
  end

  it "fails on an empty order" do
    result = described_class.call(params: { items: [] })

    expect(result).to have_attributes(terminus: :failure, error: :invalid, failed_step: :validate)
  end
end
```

## Fake dependencies through ctx

Steps get their dependencies as keyword arguments with defaults, for example `gateway: PaymentGateway`. A test passes a fake under the same key. No stubbing of constants is needed:

```ruby
let(:declining_gateway) { Class.new { def self.charge(_amount) = nil } }

it "passes a fake dependency through ctx" do
  result = described_class.call(params: { items: %w[book] }, gateway: declining_gateway)

  expect(result).to have_attributes(error: :declined, failed_step: :charge)
  expect(result[:released_after]).to eq(:charge)
end
```

The fake reaches `Billing::Charge` too, because a [nested](nested.md) operation shares the ctx.

## Fake a nested operation

`nested` calls the inner operation through `Inner.nested_call(ctx)`. Stub that method to replace
the inner operation. It gets the outer ctx Hash and returns a `Result`:

```ruby
it "fakes the nested operation" do
  allow(Billing::Charge).to receive(:nested_call) do |ctx|
    ctx[:payment_id] = "pay_test"
    Octorail::Result.new(:success, ctx)
  end

  expect(described_class.call(params: { items: %w[book] })[:payment_id]).to eq("pay_test")
end
```

The stub works whether or not the operation has been compiled already. It also works in traced
calls: there, `nested_call` gets the trace node as a second argument, which a block stub may
ignore.

## A nested operation on its own

To test the inner operation exactly as the outer one runs it, build the ctx Hash by hand and call
`nested_call`. It runs on that very Hash, without copying it:

```ruby
RSpec.describe Billing::Charge do
  it "runs on a ctx built by hand, as Orders::Place would pass it" do
    ctx = { order: { total: 10 }, gateway: Class.new { def self.charge(_) = "pay_1" } }

    result = described_class.nested_call(ctx)

    expect(result).to be_success
    expect(ctx[:payment_id]).to eq("pay_1") # nested_call works on the same Hash
  end
end
```

## A single step

Steps are public instance methods. `Op.new` gives an unfrozen instance to call them on:

```ruby
describe "#build_order" do
  it "sums the items" do
    ctx = {}
    described_class.new.build_order(ctx, params: { items: %w[a b c] })

    expect(ctx[:order][:total]).to eq(30)
  end
end
```

Running all the examples above:

```text
Orders::Place
  fakes the nested operation
  places an order
  fails on an empty order
  passes a fake dependency through ctx
  #build_order
    sums the items

Billing::Charge
  runs on a ctx built by hand, as Orders::Place would pass it

Finished in 0.01451 seconds (files took 0.06835 seconds to load)
6 examples, 0 failures
```

## Reading a failure: `call_traced`

When a spec fails and it isn't clear why, swap `call` for `call_traced` and put the trace in the
failure message (see [tracing](tracing.md)):

```ruby
it "places an order with a declining gateway" do
  result = described_class.call_traced(params: { items: %w[book] },
                                       gateway: Class.new { def self.charge(_) = nil })

  expect(result).to be_success, result.trace.to_s
end
```

```text
  1) Orders::Place places an order with a declining gateway
     Failure/Error: expect(result).to be_success, result.trace.to_s

       Orders::Place  0.679 ms
       ├── ✓ validate  0.006 ms
       ├── ✓ build_order  0.001 ms
       ├── ✗ nested Billing::Charge  0.658 ms
       │   └── ✗ charge  0.003 ms
       ├── · failure release_stock  0.002 ms
       └── failure error=:declined failed_step=:charge
```

`trace.to_h` works for assertions on the path itself, for example "the `:admin` branch was taken".

## Catch broken operations in CI

`Octorail.compile_all!` compiles every loaded operation. A broken declaration fails the suite even
if no spec calls that operation (see [compilation](compilation.md)):

```ruby
# spec/spec_helper.rb
RSpec.configure do |config|
  config.before(:suite) do
    Rails.application.eager_load! if defined?(Rails) # load every operation first
    Octorail.compile_all!
  end
end
```

## Limits

- **Input is keyword arguments.** Write `Op.call(**hash)`. `Op.call(hash)` is an `ArgumentError`. The copy is shallow: mutating a nested object in ctx affects the caller's object.
- **`Op.new` is not frozen, so a unit test of one step won't catch an instance-variable write.** The compiled operation runs on one frozen instance and raises `Octorail::FrozenOperationError` there. Keep state in ctx (see [errors](errors.md)).
- **Stub `nested_call`, not `call`, to fake a nested operation.** `nested` never goes through `call`.
- **The operation instance has no public `call`.** Call steps one by one, or call the class.
- **Octorail errors are not `StandardError`** (they are `ScriptError`). `expect { }.to raise_error(Octorail::CompileError)` works, but a bare `rescue => e` in test helpers won't catch them (see [errors](errors.md)).
