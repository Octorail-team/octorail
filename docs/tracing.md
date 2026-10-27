# Tracing

A trace records the path one call took through an operation. It covers every step, branch,
wrap and nested operation, with outcomes and, optionally, durations. Use it to answer "why did
this fail?" in a console, a failing spec, or an error tracker in production.

## Levels

| level | records | cost (10 trivial steps) |
|---|---|---|
| `:off` (default) | nothing: `result.trace` is `nil`, plain code runs | 341–411 ns, 2 objects (same as without tracing) |
| `:path` | steps and their outcomes, switch branches, recover, wrapper results, nested operations | 1.2–2.1 µs, 15 objects |
| `:profile` | `:path` plus the duration of every node (monotonic clock) | 2.5–3.3 µs |

Only operations and calls with tracing on pay this cost. Even `:profile` stays far below an untraced Trailblazer call (see [performance](performance.md)).

Ways to turn tracing on:

- `Op.call_traced(**input)` traces a single call, always at `:profile`. Use it in a console or a failing spec.
- `Octorail.configure { |c| c.trace = :path }` traces every call (see [configuration](configuration.md)).
- `configure trace: :path` inside one operation (or an `abstract!` base) traces every call of that operation.

Compilation generates a second, traced variant of the method. Plain `call` stays untouched. The traced variant is installed only when something needs it. `to_ruby(traced: true)` shows it.

## A failure

```ruby
class Transaction
  def self.call(_ctx) = yield # stands in for ActiveRecord::Base.transaction
end

module Billing
  class Charge < Octorail::Operation
    step :authorize
    step :charge, error: :declined

    def authorize(_ctx) = true
    def charge(ctx) = ctx[:card] != "declined"
  end
end

module Orders
  class Checkout < Octorail::Operation
    step :validate
    switch :flow_for do
      on(:admin) { step :grant_discount }
      on(:customer)
    end
    wrap Transaction do
      step :create_order
      nested Billing::Charge
      failure :charge_wallet, recover: true
    end
    failure :log_failure

    def validate(_ctx) = true
    def flow_for(_ctx, role:) = role
    def grant_discount(_ctx) = true
    def create_order(ctx) = ctx[:order] = { id: 7 }
    def charge_wallet(ctx) = ctx[:wallet_balance].to_i >= 100
    def log_failure(_ctx) = true
  end
end

result = Orders::Checkout.call_traced(role: :admin, card: "declined", wallet_balance: 20)
puts result.trace
```

```text
Orders::Checkout  0.525 ms
├── ✓ validate  0.003 ms
├── switch flow_for → :admin  0.006 ms
│   └── ✓ grant_discount  0.001 ms
├── wrap Transaction → false  0.39 ms
│   ├── ✓ create_order  0.001 ms
│   ├── ✗ nested Billing::Charge  0.382 ms
│   │   ├── ✓ authorize  0.001 ms
│   │   └── ✗ charge  0.002 ms
│   └── ↺ recover charge_wallet (not recovered)  0.002 ms
├── · failure log_failure  0.001 ms
└── failure error=:declined failed_step=:charge
```

The first traced call of an operation also installs its traced variant. That is why
`Billing::Charge` takes 0.38 ms here and microseconds on later calls.

Marks:

| mark | meaning |
|---|---|
| `✓` | succeeded |
| `✗` | failed |
| `·` | ran, result ignored (`pass`, failure steps) |
| `↺` | recover step |
| `!` | raised |

A wrap shows what its wrapper returned. A switch shows the branch its decider picked. The last line shows the terminus with `error` / `failed_step`.

## `to_h`

`trace.to_h` returns the same tree as a nested Hash, for JSON logs and for assertions in tests:

```ruby
pp result.trace.to_h
```

```text
{operation: "Orders::Checkout",
 level: :profile,
 terminus: :failure,
 error: :declined,
 failed_step: :charge,
 duration_ms: 0.525,
 nodes:
  [{type: :step, name: :validate, outcome: :success, duration_ms: 0.003},
   {type: :switch,
    name: :flow_for,
    outcome: :success,
    branch: :admin,
    duration_ms: 0.006,
    nodes:
     [{type: :step,
       name: :grant_discount,
       outcome: :success,
       duration_ms: 0.001}]},
   {type: :wrap,
    name: "Transaction",
    outcome: :failure,
    duration_ms: 0.39,
    nodes:
     [{type: :step,
       name: :create_order,
       outcome: :success,
       duration_ms: 0.001},
      {type: :nested,
       name: "Billing::Charge",
       outcome: :failure,
       duration_ms: 0.382,
       nodes:
        [{type: :step,
          name: :authorize,
          outcome: :success,
          duration_ms: 0.001},
         {type: :step, name: :charge, outcome: :failure, duration_ms: 0.002}]},
      {type: :recover,
       name: :charge_wallet,
       outcome: :not_recovered,
       duration_ms: 0.002}]},
   {type: :failure, name: :log_failure, outcome: :ran, duration_ms: 0.001}]}
```

Outcomes:

- `:success` / `:failure` for steps, wraps and nested operations;
- `:ran` for `pass` and failure steps;
- `:recovered` / `:not_recovered` for recover steps;
- `:raised` for a node an exception left;
- `:failed` for a container the call left through a failure exit inside it.

## Exceptions carry the trace

In a traced call, an exception leaves with the trace attached as `e.octorail_trace`. The
exception's class, message and backtrace stay the same, so `rescue IOError` and error
trackers keep working.

```ruby
module Payments
  class Capture < Octorail::Operation
    configure trace: :path
    step :authorize
    step :capture

    def authorize(_ctx) = true
    def capture(_ctx) = raise(IOError, "gateway timeout")
  end
end

begin
  Payments::Capture.call
rescue IOError => e
  puts e.message
  puts e.octorail_trace
end
```

```text
gateway timeout
Payments::Capture
├── ✓ authorize
├── ! capture (raised IOError)
└── raised IOError: gateway timeout
```

At `:path` there are no durations.

### Rescued by a wrapper

A raise is recorded on the step that raised it, even when a wrapper rescues it and the call
ends with an ordinary failure:

```ruby
module Payments
  class Refund < Octorail::Operation
    wrap :with_timeout do
      step :call_gateway
    end
    failure :notify_support

    def with_timeout(_ctx)
      yield
    rescue IOError
      false
    end

    def call_gateway(_ctx) = raise(IOError, "connection reset")
    def notify_support(_ctx) = true
  end
end

puts Payments::Refund.call_traced.trace
```

```text
Payments::Refund  0.019 ms
├── wrap with_timeout → false  0.011 ms
│   └── ! call_gateway (raised IOError, rescued by with_timeout)  0.004 ms
├── · failure notify_support  0.001 ms
└── failure error=:failure failed_step=:with_timeout
```

### A traced operation called from a step

`nested` operations are part of the outer trace. But a step may call another operation directly,
for example `Payments::Capture.call(...)`. If that operation is traced and raises, its trace is
kept under the step that called it:

```ruby
module Orders
  class Pay < Octorail::Operation
    step :validate
    step :capture_payment

    def validate(_ctx) = true
    def capture_payment(ctx) = Payments::Capture.call(amount: ctx[:amount]).success?
  end
end

begin
  Orders::Pay.call_traced(amount: 100)
rescue IOError => e
  puts e.octorail_trace
  pp e.octorail_trace.to_h[:nodes][1]
end
```

```text
Orders::Pay  0.135 ms
├── ✓ validate  0.001 ms
├── ! capture_payment (raised IOError)  0.06 ms
│   └── Payments::Capture
│       ├── ✓ authorize
│       ├── ! capture (raised IOError)
│       └── raised IOError: gateway timeout
└── raised IOError: gateway timeout
{type: :step,
 name: :capture_payment,
 outcome: :raised,
 exception: "IOError",
 trace:
  {operation: "Payments::Capture",
   level: :path,
   exception: "IOError",
   nodes:
    [{type: :step, name: :authorize, outcome: :success},
     {type: :step, name: :capture, outcome: :raised, exception: "IOError"}]},
 duration_ms: 0.06}
```

## Nested operations and ctx values

```ruby
module Billing
  class Charge < Octorail::Operation
    configure trace: :path
    step :charge
    def charge(_ctx) = true
  end
end

module Orders
  class Checkout < Octorail::Operation
    step :load_user
    nested Billing::Charge

    def load_user(ctx) = ctx[:user] = { email: "ann@example.com", card: "4242 4242 4242 4242" }
  end
end

p Orders::Checkout.call.trace       # :off by default
p Billing::Charge.call.trace.class  # its own setting, called on its own
trace = Orders::Checkout.call_traced.trace
puts trace
p trace.to_s.include?("4242") || trace.to_h.inspect.include?("4242")
p trace
```

```text
nil
Octorail::Trace
Orders::Checkout  0.009 ms
├── ✓ load_user  0.002 ms
├── ✓ nested Billing::Charge  0.003 ms
│   └── ✓ charge  0.001 ms
└── success
false
#<Octorail::Trace Orders::Checkout success>
```

- **The outermost call decides.**
  - A traced call traces its `nested` operations through, whatever their own setting.
  - A `nested` operation inside an untraced call runs untraced, even with its own `trace` setting. Nobody pays for a trace that would be thrown away.
  - Called on its own, an operation uses its own setting.
- **No ctx values.** A trace holds names, outcomes, `error`, branch keys and durations. A node keeps what its step returned only as `true` / `false`. Traces go to logs and error trackers, and ctx holds personal data.

## Limits

- **No ctx values in a trace**, by design. Log what you need explicitly in a step or a failure step.
- **Settings are boot-time.** Changing `trace` on a live process under load is not supported: recompiling swaps methods (see [compilation](compilation.md)).
- **One tree, no flat event list.** Use `to_h` and walk `nodes`.
- **Only the outermost traced call attaches its trace to an exception.** It already contains every `nested` part. The trace of a separate traced call made from a step is kept under that step.
- **A frozen exception gets no trace.** The trace can't be attached to it. The exception is re-raised unchanged.
- **Octorail never wraps an exception in its own exception class.** That would break every `rescue SomeError`. The trace is attached to the original exception object instead.
