# Fail fast and recover

By default a failed step runs every failure step declared after it, then returns
`:failure` (see [steps](steps.md)). Two options change that. `fail_fast: true` cuts the
failure track short. `recover: true` lets a failure step bring the operation back to the
success track.

## `fail_fast: true` on a step

If the step fails, the failure track is skipped and the operation ends at once with the
`:fail_fast` terminus. `error` and `failed_step` are set as usual. If the step succeeds,
the option does nothing.

```ruby
module Orders
  class Cancel < Octorail::Operation
    step :find_order, error: :not_found, fail_fast: true
    step :cancel, error: :not_cancellable
    failure :notify_support

    def find_order(ctx, id:) = ctx[:order] = { 1 => { id: 1, state: "shipped" } }[id]
    def cancel(_ctx, order:) = order[:state] == "new"
    def notify_support(ctx) = (ctx[:log] ||= []) << :notify_support
  end
end

missing = Orders::Cancel.call(id: 99)
p missing.terminus, missing.error, missing.failed_step, missing.failure?, missing.ctx[:log]

shipped = Orders::Cancel.call(id: 1)
p shipped.terminus, shipped.error, shipped.ctx[:log]
```

```text
:fail_fast
:not_found
:find_order
true
nil
:failure
:not_cancellable
[:notify_support]
```

`:fail_fast` is a failure: `success?` is false. Callers that only check `success?` don't
need to know it exists. Callers that care can match on `terminus`.

## `fail_fast: true` on a failure step

The failure step runs, then the rest of the failure track is skipped and the operation
ends with `:fail_fast`. The option is positional: failure steps declared before this one
still run.

```ruby
module Payments
  class Charge < Octorail::Operation
    step :authorize
    failure :release_hold
    failure :alert_fraud_team, fail_fast: true
    failure :log_failure

    def authorize(ctx) = !ctx[:declined]
    def release_hold(ctx) = (ctx[:log] ||= []) << :release_hold
    def alert_fraud_team(ctx) = (ctx[:log] ||= []) << :alert_fraud_team
    def log_failure(ctx) = (ctx[:log] ||= []) << :log_failure
  end
end

result = Payments::Charge.call(declined: true)
p result.terminus, result.error, result.failed_step, result.ctx[:log]
```

```text
:fail_fast
:failure
:authorize
[:release_hold, :alert_fraud_team]
```

On both `step` and `failure`, `fail_fast` means the same thing: cut the failure track
and end with `:fail_fast`. It costs nothing at runtime, because the compiler simply
stops emitting failure steps after that point.

## `recover: true`: back to the success track

A failure step with `recover: true` is the only failure step whose return value matters:

- **truthy**: the operation goes back to the success track, at the next `step` / `pass`
  declared after the recovering step;
- **falsy**: the failure track goes on as if the step were a plain failure step.

A recovering step runs for a failure of **any** step declared before it, like every
failure step. The method decides what it can recover from, by looking at the
`failed_step:` and `error:` keywords:

```ruby
module Payments
  class Pay < Octorail::Operation
    step :validate, error: :invalid
    step :charge_card, error: :declined
    failure :charge_wallet, recover: true
    step :send_receipt
    failure :log_failure

    def validate(_ctx, amount:) = amount.positive?
    def charge_card(ctx, card_ok: true) = card_ok && ctx[:paid_with] = :card

    def charge_wallet(ctx, failed_step:, wallet: 0, amount:)
      return false unless failed_step == :charge_card
      return false if wallet < amount

      ctx[:paid_with] = :wallet
    end

    def send_receipt(ctx, paid_with:) = (ctx[:log] ||= []) << "receipt (#{paid_with})"

    def log_failure(ctx, error:, failed_step:)
      (ctx[:log] ||= []) << "failed: #{error} at #{failed_step}"
    end
  end
end

[
  { amount: 10 },
  { amount: 10, card_ok: false, wallet: 50 },
  { amount: 10, card_ok: false, wallet: 5 },
  { amount: -1, wallet: 50 }
].each do |input|
  r = Payments::Pay.call(**input)
  puts "#{input.inspect.ljust(46)} => #{r.terminus} error=#{r.error.inspect} log=#{r.ctx[:log]}"
end
```

```text
{amount: 10}                                   => success error=nil log=["receipt (card)"]
{amount: 10, card_ok: false, wallet: 50}       => success error=nil log=["receipt (wallet)"]
{amount: 10, card_ok: false, wallet: 5}        => failure error=:declined log=["failed: declined at charge_card"]
{amount: -1, wallet: 50}                       => failure error=:invalid log=["failed: invalid at validate"]
```

After a successful recovery the result is an ordinary success: `error` and
`failed_step` are `nil`. After a failed recovery the result keeps the original failure
(`:declined` at `:charge_card`). The recovering step's own name never becomes
`failed_step`.

Operations without `recover:` compile exactly as before. With it, the steps before the
recovering step record their outcome in a local variable instead of returning
immediately. That is still plain `if`s, with no runtime cost.

### `recover: true` with `fail_fast: true`

`fail_fast` applies only when the recovery fails. A successful recovery goes back to the
success track as usual:

```ruby
module Payments
  class Refund < Octorail::Operation
    step :refund_card
    failure :refund_to_wallet, recover: true, fail_fast: true
    failure :log_failure
    step :notify

    def refund_card(ctx) = ctx[:card_ok]
    def refund_to_wallet(ctx) = ctx[:wallet_ok]
    def log_failure(ctx) = (ctx[:log] ||= []) << :log_failure
    def notify(ctx) = (ctx[:log] ||= []) << :notify
  end
end

p Payments::Refund.call(card_ok: false, wallet_ok: true).then { [_1.terminus, _1.ctx[:log]] }
p Payments::Refund.call(card_ok: false, wallet_ok: false).then { [_1.terminus, _1.ctx[:log]] }
```

```text
[:success, [:notify]]
[:fail_fast, nil]
```

## `error:` and `failed_step:` in failure steps

Any failure step, recovering or not, may declare the keywords `error:` and/or
`failed_step:`. These are not read from ctx. The compiler fills them with literals known
at each place where the operation can fail, so they cost nothing. The values are the
ones the result will carry: the failed step's `error:` symbol (or `:failure`), and its
name.

`log_failure` above uses both. Other keywords on a failure step come from ctx as usual
(`amount:` in `charge_wallet`). Anywhere else (a `step`, a `pass`, a wrapper method, a
switch decider) these two keywords are a `CompileError`: they would have to come from
ctx, where both names are [reserved](steps.md#reserved-keys), so the step could never run.

```text
Octorail::CompileError: Users::Notify: step :notify takes error:, which only failure steps get (it's a reserved key, never in ctx)
```

## Limits

- **No `pass_fast`.** Trailblazer's version ("truthy → end with success") is useless on a
  linear railway: every step after it is unreachable. A guard variant ("truthy → end,
  falsy → continue") was dropped too. To skip steps on success, put them in a
  [switch](switch.md) branch that is taken only when they should run.
- **No jumps to a named step and no custom wiring** (`Output(...) => Id(...)`, extra
  tracks). The railway is always linear, so the generated code is plain `if` / `return`.
  For different flows use [switch](switch.md). To get back from failure, use
  `recover: true`.
- **`recover:` is only for `failure` steps.** On `step` it raises
  `ArgumentError: ... unknown options [:recover], allowed: [:error, :fail_fast]`.
- **`pass` takes no options**, because its result is ignored:
  `ArgumentError: ... pass :a: unknown options [:fail_fast], allowed: []`.
- **`fail_fast:` and `recover:` must be `true` or `false`, and `error:` must be a
  Symbol.** Anything else raises
  `ArgumentError: ... fail_fast: must be true or false, got :yes`.
- **Failure steps are positional.** A failure step, recovering or not, covers only the
  steps declared before it. A step a subclass appends after the parent's failure steps is
  not covered by them (see [inheritance](inheritance.md)).
- **No exception DSL.** `recover:` reacts to failures (falsy steps), not to exceptions.
  A step that may raise rescues in its own method and returns falsy, and then
  `recover:` can handle it.
