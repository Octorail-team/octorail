# wrap

`wrap` runs a group of steps inside a wrapper: a transaction, a lock, a retry loop, a
timeout. The wrapper gets a block that runs the steps. Whatever the wrapper returns
decides whether the whole group succeeded.

## The wrapper contract

A wrapper is either an object that responds to `.call(ctx) { }`, or the name (a Symbol)
of an instance method of the operation.

1. It is called with ctx and a block.
2. `yield` runs the steps inside. It returns `true` if they all passed and `false` if
   one failed.
3. **The wrapper's return value is the wrap's result.** Truthy goes on along the
   success track, falsy goes to the failure track. So the wrapper can roll back, it
   can compensate (undo and return `false`), or it can even recover (return `true`
   after a failed step).
4. Exceptions raised by the steps pass through the wrapper. The wrapper may rescue them.

The gem knows nothing about databases. There is no `rollback:` option, because the
wrapper decides by itself how to roll back.

## An object wrapper

```ruby
require "octorail"

# A fake store with transactions, standing in for a database.
module Store
  @rows = []
  class << self
    attr_reader :rows

    def transaction
      snapshot = @rows.dup
      ok = yield
      @rows = snapshot unless ok
      ok
    end
  end
end

class Transaction
  def self.call(_ctx)
    Store.transaction { yield }
  end
end

module Orders
  class Checkout < Octorail::Operation
    step :validate
    wrap Transaction do
      step :create_order
      step :charge, error: :declined
      failure :mark_order_failed
    end
    pass :send_receipt
    failure :log_failure

    def validate(ctx, cart:) = !cart.empty?
    def create_order(ctx, cart:) = Store.rows << ctx[:order] = { items: cart }
    def charge(ctx, card:) = card == "ok"
    def mark_order_failed(ctx) = puts("  inside the wrap: mark_order_failed")
    def send_receipt(ctx) = puts("  receipt sent")
    def log_failure(ctx, error:, failed_step:) = puts("  outside the wrap: log_failure(#{error}, #{failed_step})")
  end
end

puts "success:"
p Orders::Checkout.call(cart: ["book"], card: "ok")
puts "rows: #{Store.rows.size}"
puts
puts "charge fails:"
p Orders::Checkout.call(cart: ["book"], card: "bad")
puts "rows: #{Store.rows.size} (the second order was rolled back)"
```

```text
success:
  receipt sent
#<Octorail::Result terminus=:success error=nil failed_step=nil ctx={cart: ["book"], card: "ok", order: {items: ["book"]}}>
rows: 1

charge fails:
  inside the wrap: mark_order_failed
  outside the wrap: log_failure(declined, charge)
#<Octorail::Result terminus=:failure error=:declined failed_step=:charge ctx={cart: ["book"], card: "bad", order: {items: ["book"]}}>
rows: 1 (the second order was rolled back)
```

A wrapper that is a named class or module is referenced by its constant in the
generated code. An anonymous object is referenced through a constant the operation
keeps for it. Write wrappers with `yield`, not `&block`: capturing a block allocates
a Proc on every call.

## Failure inside a wrap

Outside the wrap, the wrap counts as **one step**. Inside, it has its own railway with
the same rules:

1. A step inside fails. The failure steps **inside** the block that are declared after
   it run (`mark_order_failed` above).
2. The block returns `false` to the wrapper, and the wrapper finishes (in this
   example, it rolls back).
3. If the wrapper returns falsy, the failure steps **outside** that are declared after
   the wrap run (`log_failure`).
4. The result carries the `error` and `failed_step` of the step that actually failed
   inside (`:declined`, `:charge`).

So a transaction rolls back before any outer failure step runs. Failure steps inside a
transaction wrap run **inside** the transaction, and their writes are rolled back with
it. Put a failure step whose writes must persist (a log, a status) outside the wrap.

Wraps nest. An inner wrapper finishes before an outer one, so the inner rollback
happens first.

## A wrapper method, and a wrapper that fails by itself

A Symbol names an instance method. Its keyword arguments come from ctx, exactly as
for a step (see [steps](steps.md)).

If the wrapper returns falsy although no step inside failed, `error:` is the error.
`failed_step` is then the wrapper method's name, or `nil` for an object wrapper.

```ruby
require "octorail"

module Payments
  class Capture < Octorail::Operation
    # A wrapper method: kwargs come from ctx, like a step's.
    wrap :with_lock, error: :locked do
      step :capture
    end

    def with_lock(ctx, payment:)
      return false if payment[:locked] # fails by itself: no step ran
      yield
    end

    def capture(ctx, payment:) = payment[:captured] = true
  end

  # An object wrapper that fails by itself
  class Gate
    def self.call(ctx) = ctx[:open] ? yield : false
  end

  class Refund < Octorail::Operation
    wrap Gate, error: :closed do
      step :refund
    end
    def refund(ctx) = true
  end
end

p Payments::Capture.call(payment: { locked: true }).then { [_1.error, _1.failed_step] }
p Payments::Capture.call(payment: {}).then { [_1.terminus, _1.ctx[:payment]] }
p Payments::Refund.call(open: false).then { [_1.error, _1.failed_step] }
```

```text
[:locked, :with_lock]
[:success, {captured: true}]
[:closed, nil]
```

Without `error:`, a wrapper that fails by itself reports the default error,
`:failure`. When a step inside failed, that step's `error` and `failed_step` are
reported, and the wrap's `error:` doesn't apply.

## Retries and timeouts

Because the wrapper owns the block, it can run the block again, or turn an exception
into a failure:

```ruby
require "octorail"

# Runs the block up to 3 times while it fails.
class Retry
  def self.call(_ctx)
    3.times { return true if yield }
    false
  end
end

# Turns a timeout inside into a plain failure.
class Timeoutish
  def self.call(_ctx)
    yield
  rescue IOError
    false
  end
end

module Payments
  class Charge < Octorail::Operation
    wrap Retry do
      step :call_gateway
    end
    wrap Timeoutish, error: :timeout do
      step :fetch_receipt
    end

    def call_gateway(ctx)
      ctx[:attempts] = ctx.fetch(:attempts, 0) + 1
      ctx[:attempts] >= 2 # fails on the first attempt
    end

    def fetch_receipt(ctx) = ctx[:slow] ? raise(IOError, "read timeout") : true
  end
end

r = Payments::Charge.call
p [r.terminus, r.ctx[:attempts]]
r = Payments::Charge.call(slow: true)
p [r.terminus, r.error, r.failed_step]
```

```text
[:success, 2]
[:failure, :timeout, nil]
```

The rescued `IOError` is gone from the result, but a trace still shows it on the step
that raised it: `! fetch_receipt (raised IOError, rescued by Timeoutish)` (see
[tracing](tracing.md)).

## Exceptions

An exception that the wrapper does not rescue passes through it, and its `ensure`
runs. Failure steps don't run: an exception is not a failure.

```ruby
require "octorail"

class Audit
  def self.call(_ctx)
    puts "wrapper: before"
    yield
  ensure
    puts "wrapper: ensure runs"
  end
end

module Orders
  class Ship < Octorail::Operation
    wrap Audit do
      step :ship
    end
    failure :log
    def ship(_ctx) = raise(ArgumentError, "no address")
    def log(_ctx) = puts("log (not reached)")
  end
end

begin
  Orders::Ship.call
rescue ArgumentError => e
  puts "raised: #{e.message}"
end
```

```text
wrapper: before
wrapper: ensure runs
raised: no address
```

An ActiveRecord transaction rolls back on an exception by itself.

## fail_fast inside a wrap

`fail_fast: true` on a step inside a wrap still gives the wrapper `false`, so it can
roll back. Then every failure step is skipped, both inner and outer, and the operation
ends with `:fail_fast` (see [fail-fast-and-recover](fail-fast-and-recover.md)).

```ruby
require "octorail"

class Tx
  def self.call(_ctx)
    ok = yield
    puts "wrapper got #{ok.inspect}"
    ok
  end
end

module Users
  class Ban < Octorail::Operation
    wrap Tx do
      step :check_admin, fail_fast: true
      failure :inner_log
    end
    failure :outer_log
    def check_admin(ctx, admin:) = admin
    def inner_log(_ctx) = puts("inner_log")
    def outer_log(_ctx) = puts("outer_log")
  end
end

r = Users::Ban.call(admin: false)
p [r.terminus, r.failed_step]
```

```text
wrapper got false
[:fail_fast, :check_admin]
```

## Transactions (ActiveRecord)

A transaction wrapper for ActiveRecord:

```ruby
# Not executed here: needs ActiveRecord.
class Transaction
  def self.call(_ctx)
    ActiveRecord::Base.transaction(requires_new: true) do
      yield or raise ActiveRecord::Rollback
    end
  end
end
```

Pay attention to `requires_new: true`. Without it, a `transaction` call inside another
transaction joins the outer one. `ActiveRecord::Rollback` raised in the joined block is
**swallowed**: it doesn't propagate, and nothing is rolled back. With nested wraps, or
with an operation nested in one that is already in a transaction, the inner wrap's
"rollback" then silently keeps its writes. `requires_new: true` opens a savepoint, so
the inner rollback undoes exactly the inner block.

Raise `ActiveRecord::Rollback` rather than relying on the block's value: `transaction`
ignores what the block returns, so a block that ends with `false` commits.

## Limits

- **No `rollback:` option and no per-step undo** (`step :charge, undo: :refund`). The
  wrapper decides how to roll back or compensate, so the gem stays independent of any
  ORM. Put the compensation in the wrapper: undo, then return `false`.
- **An operation can't be a wrapper.** `wrap Billing::Charge` raises `ArgumentError`.
  To run an operation as a step, use [`nested`](nested.md).
- **A wrap needs a block with at least one step.** An empty `wrap` is an
  `ArgumentError`. `error:` must be a Symbol.
- **No exception DSL around a group of steps** (`rescue_from`, `rescue:`). A wrap that
  rescues `StandardError` around everything catches bugs in steps it wasn't meant for.
  Rescue in the step's own method and return falsy, or write a wrapper that rescues one
  specific exception, like `Timeoutish` above.
- **Failure steps inside a transaction wrap are rolled back too.** Declare failure steps
  that must persist after the wrap.
