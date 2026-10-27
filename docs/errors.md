# Errors

Octorail separates two kinds of problems. **Business failures** (invalid input, a
declined card) are failure results: `result.failure?`, `result.error`. **Mistakes in
code** (a missing step method, a key the caller forgot, a typo in an output name) are
exceptions. This page covers the exceptions: when each is raised, what it says, and
why they don't derive from `StandardError`.

## When errors are raised

| when | error | examples |
|---|---|---|
| class body is loaded | `ArgumentError` | duplicate step, unknown option, `step` in an abstract base, a non-Symbol switch key |
| compile time: first call, or `Octorail.compile_all!` | `Octorail::CompileError` | no method for a step, `**` in a signature, a `nested` cycle, calling an abstract operation |
| during a call | `Octorail::MissingKeyError` | a step's required keyword is not in ctx |
| | `Octorail::UnknownBranchError` | a switch decider returned a value with no `on(...)` branch |
| | `Octorail::FrozenOperationError` | a step wrote an instance variable |
| | `Octorail::MissingOutputError` | a successful call didn't set a declared output |
| reading the result | `Octorail::UnknownOutputError` | `result[:key]` or pattern matching on a key that is not an output |
| | `Octorail::ReservedKeyError` | `result[:error]`, or ctx holds a reserved key |

Load-time mistakes are `ArgumentError`, like any misused Ruby method. The others derive
from `Octorail::Error`:

```text
ScriptError
└── Octorail::Error
    ├── Octorail::CompileError
    ├── Octorail::MissingKeyError
    ├── Octorail::UnknownBranchError
    ├── Octorail::FrozenOperationError
    ├── Octorail::MissingOutputError
    ├── Octorail::UnknownOutputError
    └── Octorail::ReservedKeyError
```

Compile errors surface on the first call by default. To fail at boot or in CI instead of
on the first request, run `Octorail.compile_all!` (see [compilation](compilation.md)).

## Why `ScriptError`, not `StandardError`

These errors are bugs to fix, not conditions to handle. Ruby's own `NotImplementedError`
derives from `ScriptError` for the same reason. A bare `rescue`, a `rescue => e` or a
`rescue StandardError` doesn't catch them. That covers a timeout wrapper in a
[wrap](wrap.md), a controller's catch-all, and a job's `retry_on StandardError`, so none
of those can swallow a bug or retry it forever. The error reaches the top-level handler:
Rails, Sidekiq and Sentry rescue `Exception`.

```ruby
module Orders
  class Ship < Octorail::Operation
    step :ship
    def ship(_ctx, order:) = order
  end
end

def with_retry
  yield
rescue => e
  puts "retrying after #{e.class}"
end

begin
  with_retry { Orders::Ship.call }
rescue Octorail::Error => e
  puts "reached the top: #{e.class} < #{e.class.ancestors[1]} < #{Octorail::Error.superclass}"
end
```

```text
reached the top: Octorail::MissingKeyError < Octorail::Error < ScriptError
```

`with_retry` never saw the error. To catch them on purpose, for example in a test or a
console helper, rescue `Octorail::Error` or a specific class.

## Declaration locations

Errors about a declaration end with `declared at <path>:<line>`. The path is relative to
the current directory. This applies to `CompileError`, `MissingKeyError` and
`UnknownBranchError`, and to `ArgumentError` for duplicate steps. If the line was declared
by a macro, the class-body line that called the macro is added in `(via ...)`:

```ruby
# app/macros/authorization.rb
module Authorization
  def authorize(role)
    step :"authorize_#{role}"
  end
end

# app/operations/orders/refund.rb
module Orders
  class Refund < Octorail::Operation
    extend Authorization

    authorize :admin
    step :refund
    def refund(_ctx) = true
  end
end

Orders::Refund.call
```

```text
Octorail::CompileError: Orders::Refund: step :authorize_admin has no instance method #authorize_admin
  declared at app/macros/authorization.rb:3 (via app/operations/orders/refund.rb:8)
```

The location is captured with `caller_locations` when the class body is loaded, skipping
the gem's own frames, so a call pays nothing for it. The backtrace is not rewritten.

Runtime errors from generated code point to the exact declaration that raised, even when
the same step name appears in several [switch](switch.md) branches, or the same decider
is used by two switches.

## Examples

```ruby
module Orders
  class Base < Octorail::Operation
    abstract!
  end

  class Export < Octorail::Operation
    switch :format_of do
      on(:csv) { step :to_csv }
      on(:json) { step :to_json }
    end

    def format_of(_ctx, format:) = format
    def to_csv(_ctx) = true
    def to_json(_ctx) = true
  end

  class Pay < Octorail::Operation
  end

  class Charge < Octorail::Operation
    nested Pay
  end

  class Pay
    nested Charge
  end
end

Orders::Base.call
Orders::Export.call(format: :xml)
Orders::Pay.call
Orders::Base.class_eval { step :audit }
```

```text
Octorail::CompileError: Orders::Base: is abstract, call an operation that inherits from it
Octorail::UnknownBranchError: Orders::Export: switch :format_of returned :xml, branches: :csv, :json
  declared at app/operations/orders/kinds.rb:9
Octorail::CompileError: Orders::Pay: nested operations form a cycle: Orders::Pay → Orders::Charge → Orders::Pay
  declared at app/operations/orders/kinds.rb:23
ArgumentError: Orders::Base: is abstract (shared methods and macros only), so it can't declare step :audit; declare it in the operations that inherit from it
```

The other errors, with real messages, are on their feature pages:

- `MissingKeyError`, `CompileError` for `**`, `FrozenOperationError`, `ReservedKeyError`:
  [steps](steps.md);
- `UnknownOutputError`, `MissingOutputError`: [result](result.md);
- `UnknownBranchError`: [switch](switch.md).

An exception that leaves a traced call carries the path the call took, in
`e.octorail_trace` (see [tracing](tracing.md)).

## Limits

- **Octorail errors can't be caught by `rescue StandardError`.** This is on purpose.
  Fix the code, or rescue `Octorail::Error` explicitly where you really mean it.
- **No exception DSL** (`rescue_from`, `rescue:`). Business errors are failure results.
  A step that calls something that may raise rescues in its own method, puts details in
  `ctx[:errors]` and returns falsy (see [steps](steps.md#limits)). An exception a step
  doesn't rescue propagates unchanged: same class, message and backtrace.
- **No `otherwise` branch in a switch.** An unknown value is a bug, so it raises
  `UnknownBranchError` instead of falling through. List every value with `on(...)`.
- **Reserved ctx keys are checked when the result is read, not during the call.** The
  hot path stays free. `ReservedKeyError` shows up when you read the result.
