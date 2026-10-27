# Guide: building a checkout

This page builds one operation from scratch: an order checkout that validates
the cart, charges a card inside a transaction, picks a delivery flow and sends
a receipt. Every feature it touches has its own page; this one shows how they
fit together. All output below is real.

## 1. A first operation

An operation is a class with steps. A step is an instance method; it gets
`ctx`, a plain Hash, and its return value decides the track: truthy goes on,
falsy switches to failure.

```ruby
module Orders
  class Validate < Octorail::Operation
    step :check_items, error: :empty_cart
    step :check_address, error: :no_address

    def check_items(_ctx, items:) = items.any?
    def check_address(_ctx, address: nil) = !address.nil?
  end
end

Orders::Validate.call(items: [{ sku: "A1", price: 30 }], address: "Kyiv")
Orders::Validate.call(items: [], address: "Kyiv")
Orders::Validate.call(address: "Kyiv")
```

```text
#<Octorail::Result terminus=:success error=nil failed_step=nil ctx={items: [{sku: "A1", price: 30}], address: "Kyiv"}>
#<Octorail::Result terminus=:failure error=:empty_cart failed_step=:check_items ctx={items: [], address: "Kyiv"}>
Octorail::MissingKeyError: Orders::Validate: step :check_items requires :items, but ctx has no :items (ctx keys: :address)
  declared at tmp/docs-guide/guide.rb:6
```

- Keyword arguments are read from ctx. A required one (`items:`) that is missing
  raises before the step runs. An optional one (`address: nil`) gets its
  default. See [steps](steps.md).
- `error:` names the failure; the result also says which step failed. See
  [result](result.md).
- The input keywords become ctx.

## 2. What it compiles to

The DSL is not interpreted at call time. On the first call the operation is
compiled into one plain Ruby method, and `to_ruby` shows it:

```ruby
puts Orders::Validate.to_ruby
```

```text
def __octorail_call(ctx)
  unless check_items(ctx, items: ctx.fetch(:items) { __octorail_missing_key(0, :items, ctx, :check_items) })
    return ::Octorail::Result.new(:failure, ctx, :empty_cart, :check_items)
  end
  ok =
    if ctx.key?(:address)
      check_address(ctx, address: ctx[:address])
    else
      check_address(ctx)
    end
  unless ok
    return ::Octorail::Result.new(:failure, ctx, :no_address, :check_address)
  end
  ::Octorail::Result.new(:success, ctx)
rescue FrozenError => e
  __octorail_frozen!(e)
end
```

That is the whole runtime: method calls, `if` and `return`. See
[compilation](compilation.md) and [performance](performance.md).

## 3. The checkout

Now the full flow. It reuses `Validate`, charges through a second operation
inside a transaction, branches on delivery type and logs failures.

```ruby
module Payments
  class Charge < Octorail::Operation
    step :authorize, error: :declined
    step :capture

    def authorize(_ctx, total:, card:) = card != "4000 0000 0000 0002"
    def capture(ctx, total:) = ctx[:payment_id] = "pay_#{total}"
  end
end

# Any object with `call(ctx) { ... }` wraps a group of steps. Here a fake
# database that logs what it does; in Rails this is a transaction.
class Transaction
  def self.call(_ctx, &) = DB.transaction(&)
end

module Orders
  class Checkout < Octorail::Operation
    output :order

    nested Orders::Validate
    step :price
    wrap Transaction do
      step :create_order
      nested Payments::Charge
    end
    switch :delivery_for do
      on(:pickup)
      on(:courier) { step :book_courier }
    end
    pass :send_receipt
    failure :log_failure

    def price(ctx, items:) = ctx[:total] = items.sum { _1[:price] }
    def create_order(ctx, total:) = ctx[:order] = { id: 1, total: }
    def delivery_for(_ctx, delivery: :courier) = delivery
    def book_courier(ctx, address:) = ctx[:courier] = "booked for #{address}"
    def send_receipt(ctx, order:) = (ctx[:receipt_sent] = order[:id])
    def log_failure(_ctx, error:, failed_step:) = puts("  checkout failed: #{error} at #{failed_step}")
  end
end
```

What each piece does:

- `nested Orders::Validate` runs another operation on the same ctx. Its
  failure becomes this operation's failure. See [nested](nested.md).
- `wrap Transaction do ... end` runs the steps inside the wrapper's block. If a
  step inside fails, the block returns false, the wrapper rolls back, and the
  operation goes to the failure track. See [wrap](wrap.md).
- `switch :delivery_for` calls the decider and runs the branch for the Symbol
  it returns. See [switch](switch.md).
- `pass` runs, and its result is ignored.
- `failure` steps run only on the failure track. They may take `error:` and
  `failed_step:`. See [fail fast and recover](fail-fast-and-recover.md).
- `output :order` declares what a successful result exposes.

### Success

```ruby
input = { items: [{ sku: "A1", price: 30 }, { sku: "B2", price: 12 }],
          address: "Kyiv", card: "4242 4242 4242 4242" }

result = Orders::Checkout.call(**input)
result.success?   # => true
result[:order]    # => {id: 1, total: 42}
DB.log            # => [:begin, :commit]
```

### A declined card

```ruby
result = Orders::Checkout.call(**input, card: "4000 0000 0000 0002")
```

```text
  checkout failed: declined at authorize
```

```ruby
result.terminus     # => :failure
result.error        # => :declined
result.failed_step  # => :authorize
DB.log              # => [:begin, :rollback]
```

The error and the failed step come from inside `Payments::Charge`, two levels
down. The transaction rolled back because its block returned false.

### Pattern matching

```ruby
case Orders::Checkout.call(**input, delivery: :pickup)
in { success: true, order: { id: } } then puts "order #{id}"
end
```

```text
order 1
```

### An unknown branch is a bug, not a failure

```ruby
Orders::Checkout.call(**input, delivery: :drone)
```

```text
Octorail::UnknownBranchError: Orders::Checkout: switch :delivery_for returned :drone, branches: :pickup, :courier
  declared at tmp/docs-guide/guide.rb:57
```

Errors like this one point at the declaration. All errors Octorail raises are
`ScriptError`s, so a `rescue => e` in application code won't swallow them. See
[errors](errors.md).

## 4. Seeing the path

`call_traced` runs the same flow and records which way it went:

```ruby
puts Orders::Checkout.call_traced(**input, card: "4000 0000 0000 0002").trace
```

```text
Orders::Checkout
├── ✓ nested Orders::Validate
│   ├── ✓ check_items
│   └── ✓ check_address
├── ✓ price
├── wrap Transaction → false
│   ├── ✓ create_order
│   └── ✗ nested Payments::Charge
│       └── ✗ authorize
├── · failure log_failure
└── failure error=:declined failed_step=:authorize
```

(Durations are cut from this output.) Turn tracing on for an operation or
globally, and exceptions carry the trace too. See [tracing](tracing.md) and
[configuration](configuration.md).

## 5. Testing it

```ruby
# a step on its own: Op.new is a plain, unfrozen instance, and the step is a
# plain method, so pass its keywords yourself
Orders::Checkout.new.price({}, items: [{ price: 5 }])  # => 5

# the operation with its nested parts faked
allow(Payments::Charge).to receive(:nested_call) do |ctx|
  Octorail::Result.new(:failure, ctx, :declined, :authorize)
end
```

See [testing](testing.md).

## Where next

- Sharing steps between operations: [inheritance](inheritance.md) (base
  classes, macros).
- Every rule the gem enforces is in the **Limits** section of each page.
