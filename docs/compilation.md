# Compilation

Octorail turns an operation's declarations into one plain Ruby method. Calls then run that
method. This page covers when compilation happens, how to look at the result, and when it
happens again.

## Lazy: on the first call

Declaring an operation compiles nothing. The first `call` (or `nested_call`) does.

```ruby
module Users
  class Create < Octorail::Operation
    step :validate, error: :invalid
    step :persist
    failure :log_failure

    def validate(_ctx, params:) = params[:email].to_s.include?("@")
    def persist(ctx, params:) = ctx[:user] = { id: 1, email: params[:email] }
    def log_failure(_ctx, error:, failed_step:) = warn("failed: #{error} at #{failed_step}")
  end
end

p Users::Create.compiled?
Users::Create.call(params: { email: "ann@example.com" })
p Users::Create.compiled?
```

```text
false
true
```

Compiling does the following:

- checks every declaration: missing methods, signatures, `nested` cycles;
- generates the source;
- evaluates the source into the class;
- creates **one frozen instance** of the operation, which every later call runs on.

So a call allocates nothing for the operation itself. See [performance](performance.md).

## `to_ruby`: the generated code

`to_ruby` returns the source that compilation evaluates. It shows exactly what a call does.

```ruby
puts Users::Create.to_ruby
```

```text
def __octorail_call(ctx)
  unless validate(ctx, params: ctx.fetch(:params) { __octorail_missing_key(0, :params, ctx, :validate) })
    log_failure(ctx, error: :invalid, failed_step: :validate)
    return ::Octorail::Result.new(:failure, ctx, :invalid, :validate)
  end
  unless persist(ctx, params: ctx.fetch(:params) { __octorail_missing_key(1, :params, ctx, :persist) })
    log_failure(ctx, error: :failure, failed_step: :persist)
    return ::Octorail::Result.new(:failure, ctx, :failure, :persist)
  end
  ::Octorail::Result.new(:success, ctx)
rescue FrozenError => e
  __octorail_frozen!(e)
end
```

The generated code works as follows:

- Keyword arguments are read from ctx.
- A missing required key calls an error helper. The number passed to it is the node's index, so the error can name the exact declaration.
- The failure track is unrolled into every place where it can start.
- `rescue FrozenError` costs nothing unless raised. It explains an instance-variable write in a step (see [errors](errors.md)).

`to_ruby(traced: true)` shows the traced variant (see [tracing](tracing.md)).

## Eager: `Octorail.compile_all!`

`Octorail.compile_all!` compiles every operation that is already loaded. It skips `abstract!` bases. An error in any operation then shows up at boot or in CI, not on the first request.

```ruby
class ApplicationOperation < Octorail::Operation
  abstract!
end

module Orders
  class Place < ApplicationOperation
    step :reserve
    def reserve(_ctx) = true
  end

  class Cancel < ApplicationOperation
    step :refund # no #refund method
  end
end

begin
  Octorail.compile_all!
rescue Octorail::CompileError => e
  puts "#{e.class}: #{e.message}"
end
```

```text
Octorail::CompileError: Orders::Cancel: step :refund has no instance method #refund
  declared at tmp/docs-compilation/b.rb:14
```

`compile_all!(root)` compiles only the operations under `root`. The list of operations comes from `Class#subclasses` (weak references), so there is no registry to clear when code reloads.

### Rails

The core gem has no Railtie. Add one line to an initializer, so that a broken operation fails the boot or deploy:

```ruby
# config/initializers/octorail.rb
Rails.application.config.after_initialize { Octorail.compile_all! if Rails.configuration.eager_load }
```

`after_initialize` runs after eager loading, so every operation is loaded by then. Without eager loading (development), operations compile on their first call.

### CI

The same line in `spec_helper.rb` makes the test run fail on any broken operation, including ones no spec calls. Load your operations first (for example with `Rails.application.eager_load!`):

```ruby
RSpec.configure do |config|
  config.before(:suite) { Octorail.compile_all! }
end
```

## Recompiling

Compiled code is dropped when its source changes. The next call compiles again. A change cascades to subclasses. Compiled code is dropped on:

- `step` / `pass` / `failure` / `wrap` / `nested` / `switch` / `output` / `configure` on the class;
- a step method being defined, redefined, removed or undefined, in the class or in a parent;
- `include` / `prepend` on the class;
- a change to `Octorail.config` (see [configuration](configuration.md)).

```ruby
class ShipOrder < Octorail::Operation
  step :ship
  def ship(ctx) = ctx[:shipped_by] = :courier
end

p ShipOrder.call[:shipped_by]
p ShipOrder.compiled?

class ShipOrder
  def ship(ctx) = ctx[:shipped_by] = :post # redefining a step method
end
p ShipOrder.compiled?
p ShipOrder.call[:shipped_by]

class ShipOrder
  step :notify
  def notify(ctx) = ctx[:notified] = true
end
p ShipOrder.call.ctx.keys
```

```text
:courier
true
false
:post
[:shipped_by, :notified]
```

These hooks run when code is loaded. The one change they can't see is a method defined later in a module that is **already included**. Call `invalidate!` by hand in that case:

```ruby
module Tracking
  def track(_ctx) = true
end

class ShipOrder < Octorail::Operation
  include Tracking
  step :track
end

ShipOrder.call
module Tracking
  # reopened later with a new signature: ShipOrder doesn't see the change
  def track(ctx, carrier:) = ctx[:carrier] = carrier
end
begin
  ShipOrder.call(carrier: "DHL")
rescue ArgumentError => e
  puts "#{e.class}: #{e.message}"
end
ShipOrder.invalidate!
p ShipOrder.call(carrier: "DHL")[:carrier]
```

```text
ArgumentError: missing keyword: :carrier
"DHL"
```

A new method body takes effect anyway, because the generated code calls the method by name. What goes stale is everything the compiler read from the method: its signature (which ctx keys to pass) and whether it exists.

## Threads

- Compilation runs under one global `Monitor`, with a double check. Two threads calling a fresh operation compile it once.
- The instance is set last, so a call never sees half-installed code.
- After that, calls share only the frozen instance. Each call's ctx is a local Hash, so calls never share state.

## Limits

- **Code must not change under a running call.** A call that is running while its operation recompiles (a DSL change in a console, a dev reload) may see the new helper constants. This also applies to changing settings on a live process: set them at boot (see [configuration](configuration.md)).
- **Methods added later to an already-included module aren't detected.** Call `Op.invalidate!` after reopening the module, or define step methods in the operation itself.
- **No Railtie in the core gem.** Use the one-line initializer above. Rails integration will live in a separate `octorail-rails` gem.
- **`abstract!` operations can't be compiled or called.** They hold shared methods and settings only, and `compile_all!` skips them (see [inheritance](inheritance.md)).
