# Result

`Operation.call` always returns an `Octorail::Result`. It holds the outcome (`terminus`),
the failure details and the ctx. Business failures are results, not exceptions. An
exception means a mistake in code (see [errors](errors.md)).

## Fields

| reader | on success | on failure |
|---|---|---|
| `terminus` | `:success` | `:failure` or `:fail_fast` (see [fail-fast-and-recover](fail-fast-and-recover.md)) |
| `success?` / `failure?` | `true` / `false` | `false` / `true` |
| `error` | `nil` | the failed step's `error:` symbol, `:failure` if it has none |
| `failed_step` | `nil` | name of the step that failed |
| `errors` | always `nil` | `ctx[:errors]`, whatever the step put there |
| `ctx` | the whole ctx Hash | the whole ctx Hash |
| `[key]` | `ctx[key]` | `ctx[key]` |
| `trace` | the trace of a traced call, else `nil` (see [tracing](tracing.md)) | same |

`success?` is true only for `:success`, and `failure?` is its inverse, so `:fail_fast` is
a failure.

```ruby
module Users
  class Create < Octorail::Operation
    step :validate, error: :invalid
    step :persist

    def validate(ctx, params:)
      ctx[:errors] = { email: ["is missing"] } unless params[:email]
      !ctx.key?(:errors)
    end

    def persist(ctx, params:) = ctx[:user] = { id: 7, email: params[:email] }
  end
end

ok = Users::Create.call(params: { email: "ann@example.com" })
p ok
p ok.success?, ok.failure?, ok.terminus, ok.error, ok.failed_step, ok.errors
p ok[:user], ok.ctx.keys

bad = Users::Create.call(params: {})
p bad.terminus, bad.error, bad.failed_step, bad.errors
p bad.to_h.keys
```

```text
#<Octorail::Result terminus=:success error=nil failed_step=nil ctx={params: {email: "ann@example.com"}, user: {id: 7, email: "ann@example.com"}}>
true
false
:success
nil
nil
nil
{id: 7, email: "ann@example.com"}
[:params, :user]
:failure
:invalid
:validate
{email: ["is missing"]}
[:terminus, :ctx, :error, :failed_step]
```

`errors` can be any object: a Hash, an Array, `ActiveModel::Errors`. The gem only hands
it back. On success `errors` is `nil`, even if ctx has an `:errors` key.

A result is a plain object with readers only. Two results are `==` when their class and
fields are equal. `to_h` returns `{ terminus:, ctx:, error:, failed_step: }`. The result
is not frozen, and the ctx inside it is the same Hash the steps wrote to.

## Pattern matching

Pattern matching sees the result fields `success`, `terminus`, `error`, `errors` and
`failed_step`, plus every ctx key.

```ruby
case Users::Create.call(params: { email: "bob@example.com" })
in { success: true, user: { id: } } then puts "created user #{id}"
in { error: :invalid, errors: } then puts "invalid: #{errors}"
end

case bad
in { success: true, user: } then puts "created"
in { error: :invalid, errors: } then puts "invalid: #{errors}"
end
```

```text
created user 7
invalid: {email: ["is missing"]}
```

Because result fields and ctx keys share one namespace here, ctx must not contain
`:success`, `:terminus`, `:error` or `:failed_step`. If it does, `result[...]` and
pattern matching raise `Octorail::ReservedKeyError` (see [steps](steps.md#reserved-keys)).

## Outputs

By default a result exposes the whole ctx. `output` declares the keys that are the
operation's public result. With outputs:

- each output gets a reader (`result.orders`);
- `result[key]` and pattern matching accept only declared outputs (and the result fields
  above). Any other key raises `Octorail::UnknownOutputError`, so a typo or a reach into
  the operation's internals fails loudly;
- a successful call must set every output in ctx, otherwise
  `Octorail::MissingOutputError` is raised. A key set to `nil` counts as set. Failure
  results are not checked;
- `result.ctx` still gives the whole ctx, for debugging.

```ruby
module Orders
  class Search < Octorail::Operation
    output :orders, :total

    step :load
    step :count

    def load(ctx, customer_id:) = ctx[:orders] = ["order-1", "order-2"].map { "#{customer_id}/#{_1}" }
    def count(ctx, orders:) = ctx[:total] = orders.size
  end
end

result = Orders::Search.call(customer_id: 42)
p result.orders, result.total, result[:total]
p result.class

case result
in { success: true, orders:, total: } then puts "#{total} orders: #{orders.join(", ")}"
end

begin
  result[:customer_id]
rescue Octorail::UnknownOutputError => e
  puts "#{e.class}: #{e.message}"
end

begin
  case result
  in { totl: } then p totl
  end
rescue Octorail::UnknownOutputError => e
  puts "#{e.class}: #{e.message}"
end

p result.ctx[:customer_id]
```

```text
["42/order-1", "42/order-2"]
2
2
Orders::Search::OctorailResult
2 orders: 42/order-1, 42/order-2
Octorail::UnknownOutputError: :customer_id is not an output (outputs: :orders, :total); use result.ctx[:customer_id] to debug
Octorail::UnknownOutputError: :totl is not an output (outputs: :orders, :total); use result.ctx[:totl] to debug
42
```

A successful call that forgets an output:

```ruby
module Orders
  class Search < Octorail::Operation
    output :orders, :total

    step :load

    def load(ctx, customer_id:) = ctx[:orders] = ["#{customer_id}/order-1"]
  end
end

Orders::Search.call(customer_id: 42)
```

```text
Octorail::MissingOutputError: Orders::Search: succeeded without setting output :total (ctx keys: :customer_id, :orders)
```

Compilation defines a `Result` subclass for each operation that has outputs, as the
constant `OctorailResult` on that operation (`Orders::Search::OctorailResult` above).
Operations without outputs return `Octorail::Result` itself. A subclass inherits its
parent's outputs and can add more.

## Limits

- **No ctx wrapper object.** ctx is a plain `Hash` and the result returns that same Hash.
  A wrapper would add an object and a method call on every access.
- **Reserved keys:** `:success`, `:terminus`, `:error` and `:failed_step` must not be ctx
  keys. `:errors` is reserved for failure details. Use other names, such as
  `:status` or `:failure_reason`.
- **Output names can't collide with result fields or methods** (`ctx`, `hash`, `to_h`,
  `error`, ...). The declaration raises
  `ArgumentError: Orders::Export: output :hash collides with a Result field or method`.
  Pick another name.
- **No outputs in an [abstract](inheritance.md) base.** A base class holds tools, not a
  flow, so `output` there raises `ArgumentError`. Declare outputs in the concrete
  operation.
- **With outputs, other ctx keys are hidden from `[]` and pattern matching.** This is on
  purpose. Declare the key as an output, or read `result.ctx[...]` when debugging.
