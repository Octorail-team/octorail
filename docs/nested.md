# nested

`nested` runs another operation as a step of this one. Use it to reuse a whole flow,
such as charging a card, in several operations, or to put shared steps in the middle
of a flow.

## Shared ctx

The nested operation runs on **the same ctx Hash**. Nothing is copied and there is no
input or output mapping. Its steps read their keyword arguments from that ctx, and
whatever they write is visible to the outer steps after it.

```ruby
require "octorail"

module Billing
  class Charge < Octorail::Operation
    step :authorize
    step :capture, error: :declined
    failure :void_authorization

    def authorize(ctx, amount:) = ctx[:authorization] = "auth-#{amount}"
    def capture(ctx, card:) = card == "ok"
    def void_authorization(ctx) = puts("  Billing::Charge: void #{ctx[:authorization]}")
  end
end

module Orders
  class Checkout < Octorail::Operation
    step :create_order
    nested Billing::Charge
    step :confirm
    failure :cancel_order

    def create_order(ctx) = ctx[:amount] = 100
    def confirm(ctx, authorization:) = ctx[:confirmed] = authorization
    def cancel_order(ctx, error:, failed_step:) = puts("  Orders::Checkout: cancel (#{error}, #{failed_step})")
  end
end

r = Orders::Checkout.call(card: "ok")
p r.ctx
puts
r = Orders::Checkout.call(card: "bad")
p [r.terminus, r.error, r.failed_step]
```

```text
{card: "ok", amount: 100, authorization: "auth-100", confirmed: "auth-100"}

  Billing::Charge: void auth-100
  Orders::Checkout: cancel (declined, capture)
[:failure, :declined, :capture]
```

When the inner operation fails, its own failure track runs first
(`void_authorization`). Then the `nested` step counts as failed in the outer
operation, and the outer failure steps after it run (`cancel_order`).

Because the ctx is shared, two operations that use the same key share its value. Name
the keys to avoid clashes (`:charge_id` rather than `:id`).

## error, failed_step and the inner terminus

- **The inner failure shows through.** The outer result carries the inner `error` and
  `failed_step` (`:declined`, `:capture` above).
- **`error:` replaces the error.** Use it to hide the inner operation's error codes
  behind your own. `failed_step` stays the inner step, for debugging.
- **The inner terminus doesn't leak.** An inner `:fail_fast` is an ordinary failure of
  the `nested` step outside, so the outer failure steps run. The inner operation has
  already run its own failure track, and the outer one decides how to react.
- **`fail_fast: true` on `nested`** makes an inner failure end the outer operation with
  `:fail_fast`, and skips the outer failure steps.

```ruby
require "octorail"

module Billing
  class Charge < Octorail::Operation
    step :capture, error: :declined, fail_fast: true
    def capture(_ctx) = false
  end
end

module Orders
  class Checkout < Octorail::Operation
    nested Billing::Charge
    failure :cancel_order
    def cancel_order(_ctx) = puts("  cancel_order runs: the inner :fail_fast doesn't leak")
  end

  class Renew < Octorail::Operation
    nested Billing::Charge, error: :payment_failed
  end

  class Upgrade < Octorail::Operation
    nested Billing::Charge, fail_fast: true
    failure :cancel_order
    def cancel_order(_ctx) = puts("  not reached")
  end
end

p Billing::Charge.call.then { [_1.terminus, _1.error] }
p Orders::Checkout.call.then { [_1.terminus, _1.error, _1.failed_step] }
p Orders::Renew.call.then { [_1.terminus, _1.error, _1.failed_step] }
p Orders::Upgrade.call.then { [_1.terminus, _1.error, _1.failed_step] }
```

```text
[:fail_fast, :declined]
  cancel_order runs: the inner :fail_fast doesn't leak
[:failure, :declined, :capture]
[:failure, :payment_failed, :capture]
[:fail_fast, :declined, :capture]
```

Unlike [`wrap`](wrap.md), a nested operation is a separate operation, not part of this
one's railway. That is why its terminus stops at the boundary.

## nested_call: the entry point

The outer operation calls `Billing::Charge.nested_call(ctx)`. This runs the operation
on the given Hash itself and returns its Result. `call(**input)` can't be used here,
because keyword arguments always build a new Hash, and the ctx would no longer be
shared. `nested_call` accepts only a Hash: `nested_call(id: 1)` (meant as `call`) is an
`ArgumentError: no keywords accepted`.

The nested operation is **called, not inlined**: one method call and one Result per
`nested`. Because it is called, a test can stub it.

## Testing

Use `nested_call` in two ways:

- **Stub it** to fake the nested operation in the outer operation's spec. The stub may
  write to ctx and returns a Result.
- **Call it with a hand-built ctx** to test an operation the way an outer operation
  runs it.

```ruby
require "octorail"

module Billing
  class Charge < Octorail::Operation
    step :capture, error: :declined
    def capture(ctx, card:) = ctx[:charge_id] = (card == "ok" ? "ch_1" : nil)
  end
end

module Orders
  class Checkout < Octorail::Operation
    nested Billing::Charge
    step :confirm
    def confirm(ctx, charge_id:) = ctx[:confirmed] = charge_id
  end
end

RSpec.describe Orders::Checkout do
  it "confirms with the charge the nested operation made" do
    allow(Billing::Charge).to receive(:nested_call) do |ctx|
      ctx[:charge_id] = "ch_fake"
      Octorail::Result.new(:success, ctx)
    end

    expect(described_class.call(card: "ok").ctx[:confirmed]).to eq("ch_fake")
  end

  it "fails with the nested operation's error" do
    allow(Billing::Charge).to receive(:nested_call) { |ctx| Octorail::Result.new(:failure, ctx, :declined, :capture) }

    result = described_class.call(card: "ok")
    expect([result.error, result.failed_step]).to eq(%i[declined capture])
  end
end

RSpec.describe Billing::Charge do
  it "writes into the ctx it is given, as when nested" do
    ctx = { card: "ok", order_id: 7 } # what an outer operation would pass
    result = described_class.nested_call(ctx)

    expect(result.ctx).to equal(ctx)
    expect(ctx[:charge_id]).to eq("ch_1")
  end
end
```

```text
Billing::Charge
  writes into the ctx it is given, as when nested

Orders::Checkout
  confirms with the charge the nested operation made
  fails with the nested operation's error

Finished in 0.00713 seconds (files took 0.06948 seconds to load)
3 examples, 0 failures
```

The stub keeps working in a traced call, too. A traced outer operation passes its trace
node as a second argument (`nested_call(ctx, trace)`), so a stub block may take
`|ctx, _trace|` (see [testing](testing.md) and [tracing](tracing.md)).

## Cycles

An operation that leads back to itself through `nested` would recurse until
`SystemStackError`, and maybe only on a rare path in production. Nesting an operation
in itself is an `ArgumentError` at declaration. A longer cycle is a `CompileError`
raised when the operation compiles, and it points at the declaration that closes the
cycle:

```ruby
require "octorail"

module Users
  class Create < Octorail::Operation
    step :save
    def save(_ctx) = true
  end

  class Invite < Octorail::Operation
    step :send_invite
    def send_invite(_ctx) = true
  end
end

# Reopened later, e.g. in another file:
Users::Create.nested Users::Invite
Users::Invite.nested Users::Create

begin
  Users::Create.call
rescue Octorail::CompileError => e
  puts "#{e.class}: #{e.message}"
end

begin
  Users::Create.nested Users::Create
rescue ArgumentError => e
  puts "#{e.class}: #{e.message}"
end
```

```text
Octorail::CompileError: Users::Create: nested operations form a cycle: Users::Create → Users::Invite → Users::Create
  declared at tmp/docs-nested/cycle.rb:17
ArgumentError: Users::Create: nested Users::Create: an operation can't nest itself
```

Use `Octorail.compile_all!` in a spec or at boot so that a cycle fails CI rather than
the first call (see [compilation](compilation.md)).

## Tracing

A traced call goes through `nested` into the inner operation, whatever that
operation's own `trace` setting. An untraced outer operation runs a nested one
untraced, even when the nested operation has its own `trace` setting. That setting
applies only when it is called directly. See [tracing](tracing.md).

## Limits

- **No isolated ctx** (copying in, merging declared outputs out). The ctx is shared;
  avoid key clashes by naming keys.
- **Only `Octorail::Operation` subclasses.** Other callables go in a step method or a
  [`wrap`](wrap.md). An operation can't nest itself or its own subclass, and
  longer cycles are a `CompileError`.
- **`nested_call` takes a Hash, not keywords.** Use `call(**input)` to start an
  operation, and `nested_call(ctx)` to run it on an existing ctx.
- **No inlining.** The nested operation is always called, so it can be stubbed and
  recompiled on its own.
- **No step insertion into a parent's flow** (`before:` / `after:`). To put shared
  steps in the middle of several flows, put them in an operation and `nested` it (see
  [inheritance](inheritance.md)).
- `error:` must be a Symbol and `fail_fast:` must be `true` or `false`.
