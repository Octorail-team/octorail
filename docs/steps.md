# Steps

An operation is a list of steps. Each step is an instance method. `step`, `pass` and
`failure` declare the order in which they run and what their return value means.
The list is compiled into one plain Ruby method the first time the operation is called
(see [compilation](compilation.md)).

## Declaring steps

```ruby
require "octorail"

module Users
  class Create < Octorail::Operation
    step :validate, error: :invalid
    step :persist
    pass :send_welcome
    failure :log_failure

    def validate(ctx, params:)
      ctx[:errors] = ["email is missing"] unless params[:email]
      ctx[:errors].nil?
    end

    def persist(ctx, params:)
      ctx[:user] = { id: 1, email: params[:email] }
    end

    def send_welcome(ctx, user:) = puts("welcome mail to #{user[:email]}")

    def log_failure(_ctx) = puts("Users::Create failed")
  end
end

result = Users::Create.call(params: { email: "ann@example.com" })
p result.success?, result[:user]

result = Users::Create.call(params: {})
p result.terminus, result.error, result.failed_step, result.errors
```

```text
welcome mail to ann@example.com
true
{id: 1, email: "ann@example.com"}
Users::Create failed
:failure
:invalid
:validate
["email is missing"]
```

`Operation.call` takes keyword arguments. They become `ctx`, a plain `Hash` with symbol
keys. Ruby copies `**input` into a new Hash, so writing to ctx never changes the caller's
hash. The copy is shallow: mutating a nested object, like `ctx[:params][:x] = 1`, does
change the caller's object. If you already have a hash, call `Op.call(**hash)`.
`Op.call(hash)` raises `ArgumentError`.

## What a step's return value means

| DSL | runs when | return value |
|---|---|---|
| `step :x` | on the success track | falsy (`nil`, `false`) → failure; anything else → success |
| `pass :x` | on the success track | ignored, always success |
| `failure :x` | on the failure track | ignored, the operation stays on the failure track |

When a step fails, the rest of the success track is skipped. Then every `failure` step
declared **after the failed step** runs, in order, and the operation returns a result
with the `:failure` terminus.

Failure steps are positional: a failure step covers only the steps declared before it.

```ruby
module Orders
  class Ship < Octorail::Operation
    step :reserve_stock
    failure :release_nothing
    step :charge
    failure :refund

    def reserve_stock(ctx) = !ctx[:out_of_stock]
    def charge(ctx) = !ctx[:declined]
    def release_nothing(ctx) = (ctx[:log] ||= []) << :release_nothing
    def refund(ctx) = (ctx[:log] ||= []) << :refund
  end
end

p Orders::Ship.call(out_of_stock: true).ctx[:log]
p Orders::Ship.call(declined: true).ctx[:log]
```

```text
[:release_nothing, :refund]
[:refund]
```

To stop the failure track early or return to the success track, see
[fail-fast-and-recover](fail-fast-and-recover.md).

## `error:` and `ctx[:errors]`

`error:` gives a failure a symbol, set in the DSL: `step :validate, error: :invalid`.
The symbol is baked into the generated code. If the failed step has no `error:`,
`result.error` is `:failure`. `result.failed_step` is the name of the step that failed.

A step can't pick an error symbol at runtime. If a step can fail for different reasons,
split it into several steps, each with its own `error:`. Details such as messages or an
`ActiveModel::Errors` go into `ctx[:errors]`. On failure they come back as
`result.errors`; the gem doesn't interpret them. See [result](result.md).

## Signatures: `(ctx)` and `(ctx, key:)`

A step method takes `ctx` as its only positional argument. It can also declare keyword
arguments. The compiler reads the method's parameters and passes those keys from ctx as
literal keywords, so calling a step allocates no Hash.

- **Required keyword** (`items:`): the value comes from `ctx[:items]`. If ctx has no
  `:items`, the step is not called and `Octorail::MissingKeyError` is raised. A key that
  is present with the value `nil` counts as present.
- **Optional keyword** (`discount: 0`): if ctx has the key, its value is passed, even
  when the value is `nil`. Otherwise the key is not passed and the method default applies.

```ruby
require "octorail"

module Orders
  class Place < Octorail::Operation
    step :price

    def price(ctx, items:, discount: 0, currency: "EUR")
      ctx[:total] = "#{items.sum - discount} #{currency}"
    end
  end
end

p Orders::Place.call(items: [10, 20])[:total]
p Orders::Place.call(items: [10, 20], discount: 5)[:total]
p Orders::Place.call(items: [10, 20], currency: nil)[:total]

begin
  Orders::Place.call(discount: 5)
rescue Octorail::MissingKeyError => e
  puts "#{e.class}: #{e.message}"
end
```

```text
"30 EUR"
"25 EUR"
"30 "
Octorail::MissingKeyError: Orders::Place: step :price requires :items, but ctx has no :items (ctx keys: :discount)
  declared at app/operations/orders/place.rb:5
```

Up to two optional keywords compile to `ctx.key?` branches. With three or more, the
compiler builds one Hash of the keys that are present (`**ctx.slice(...)`), which is
one allocation per call.

Because the compiler reads signatures, steps can be declared before their methods are
defined. Nothing is checked until the operation compiles.

## Dependencies through ctx

The operation instance is shared, so a step must not store anything on it. To pass
dependencies, use ctx keys with keyword defaults. Tests and callers override them per call.

```ruby
class Mailer
  def self.deliver(user) = "sent to #{user}"
end

class FakeMailer
  def self.deliver(user) = "fake mail to #{user}"
end

module Users
  class Notify < Octorail::Operation
    step :notify

    def notify(ctx, user:, mailer: Mailer)
      ctx[:delivery] = mailer.deliver(user)
    end
  end
end

p Users::Notify.call(user: "ann")[:delivery]
p Users::Notify.call(user: "ann", mailer: FakeMailer)[:delivery]
```

```text
"sent to ann"
"fake mail to ann"
```

## One frozen instance, no instance variables

Compilation creates one instance of the operation and freezes it. Every call runs on it.
No object is allocated per call for the operation, and calls share no state because ctx
is local to each call. That is also why operations are thread-safe.

Writing an instance variable in a step, including a memoizing `@x ||=` helper, raises
`Octorail::FrozenOperationError`. The original `FrozenError` is kept as `cause`.
A `FrozenError` from any other object, such as a frozen string in ctx, is re-raised
unchanged.

```ruby
module Users
  class Notify < Octorail::Operation
    step :notify

    def notify(ctx, user:, mailer: Mailer)
      @sent = mailer.deliver(user)
    end
  end
end

begin
  Users::Notify.call(user: "ann")
rescue Octorail::FrozenOperationError => e
  puts "#{e.class}: #{e.message}"
  puts "cause: #{e.cause.class}"
end
```

```text
Octorail::FrozenOperationError: Users::Notify: a step tried to set an instance variable, but operations are stateless (one frozen instance is shared by all calls). Store data in ctx, pass dependencies through ctx with keyword defaults.
cause: FrozenError
```

`Users::Notify.new` still works and returns an unfrozen instance, so you can unit-test a
single step method (see [testing](testing.md)).

## Reserved keys

`:success`, `:terminus`, `:error` and `:failed_step` are fields of the result, so they
must not be ctx keys. `:errors` is reserved for failure details. Nothing checks this
during the call. The check happens when the result is read, and raises
`Octorail::ReservedKeyError`:

- `result[:error]` (or any other result field) tells you to use the reader instead;
- pattern matching on a result whose ctx holds a reserved key raises.

```ruby
module Users
  class Find < Octorail::Operation
    step :find
    def find(ctx, id:) = ctx[:user] = "user #{id}"
  end
end

result = Users::Find.call(id: 1)
begin
  result[:error]
rescue Octorail::ReservedKeyError => e
  puts "#{e.class}: #{e.message}"
end

result = Users::Find.call(id: 1, error: "oops")
begin
  case result
  in { success: true, user: } then p user
  end
rescue Octorail::ReservedKeyError => e
  puts "#{e.class}: #{e.message}"
end
```

```text
Octorail::ReservedKeyError: :error is a Result field, use result.error
Octorail::ReservedKeyError: ctx keys :error collide with Result fields; rename them
```

## Mistakes caught early

Problems in the DSL itself raise `ArgumentError` when the class body is loaded.
Problems that need the step methods raise `Octorail::CompileError` at compile time, that
is, on the first call or in `Octorail.compile_all!`. Both errors name the declaration.

```ruby
module Users
  class Update < Octorail::Operation
    step :validate
    step :validate
  end
end
# ArgumentError: Users::Update: step :validate is already declared (step :validate)
#   declared at app/operations/users/misuse.rb:6

module Users
  class Delete < Octorail::Operation
    step :destroy, rescue: true
  end
end
# ArgumentError: Users::Delete: step :destroy: unknown options [:rescue], allowed: [:error, :fail_fast]

module Users
  class Create < Octorail::Operation
    step :persist      # no #persist method
  end
end
Users::Create.call
# Octorail::CompileError: Users::Create: step :persist has no instance method #persist
#   declared at app/operations/users/misuse.rb:26
```

See [errors](errors.md) for the full list.

## Limits

- **Steps are instance methods only.** Lambdas and callable objects can't be steps.
  There is one kind of step, it appears in the backtrace under its own name, and a
  subclass can override it. Write a method, or a [macro](inheritance.md) that defines one.
- **No `**` in a step's signature.** `def x(ctx, **opts)` raises `CompileError`,
  because a step must declare exactly the keys it reads. List them as keywords.
- **No instance variables.** The instance is frozen and shared by every call. Put data
  in ctx, and pass dependencies as ctx keys with keyword defaults.
- **`error:` is static.** There is no `error!` helper to set it at runtime. Split the
  step, and put details in `ctx[:errors]`.
- **The DSL word is `failure`, not `fail`.** `fail` is `Kernel#fail`, and
  `rubocop -a` rewrites `fail :x` into `raise :x`.
- **No exception DSL** (`rescue_from`, a `rescue:` option). A step rescues inside its
  own method and returns falsy. An exception the step doesn't rescue propagates, and a
  [wrap](wrap.md) transaction rolls back on it.

  ```ruby
  def charge(ctx, order:)
    ctx[:charge] = Gateway.charge(order.total)
  rescue Gateway::CardError => e
    ctx[:errors] = [e.message]
    false
  end
  ```
- **`pass` takes no options.** Its result is ignored, so `error:` and `fail_fast:` have
  no meaning on it.
- **A step name appears once per operation**, including inherited steps, steps inside
  [wrap](wrap.md), and steps of subclasses. The exception is different branches of one
  [switch](switch.md), and there the step must keep the same type.
