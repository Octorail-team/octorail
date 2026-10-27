# Inheritance, abstract bases and macros

Operations are Ruby classes, and you can share code between them in three ways:

- a subclass of a concrete operation **appends** steps to its parent's flow;
- an `abstract!` base class holds **shared tools** (methods, settings, macros) but no
  flow;
- a **macro** is a class method that declares steps for you.

## A subclass appends steps

A subclass runs its parent's steps first and its own after them. It can override any
step method; `super` works as usual.

```ruby
require "octorail"

module Users
  class Create < Octorail::Operation
    step :validate
    step :save

    def validate(_ctx, email:) = email.include?("@")
    def save(ctx, email:) = ctx[:user] = { email: }
  end
end

module Admin
  module Users
    class Create < ::Users::Create
      step :grant_admin # runs after the parent's steps

      def validate(ctx, email:) = super && email.end_with?("@example.com")
      def grant_admin(ctx, user:) = user[:admin] = true
    end
  end
end

p Admin::Users::Create.steps.map(&:name)
p Admin::Users::Create.call(email: "ann@example.com").ctx[:user]
p Admin::Users::Create.call(email: "ann@gmail.com").then { [_1.terminus, _1.failed_step] }
p Users::Create.call(email: "ann@gmail.com").terminus

# Redefining a step method later recompiles the operations that use it.
Users::Create.class_eval { def save(ctx, email:) = ctx[:user] = { email:, v: 2 } }
p Users::Create.call(email: "a@b.c").ctx[:user]
p Admin::Users::Create.call(email: "a@example.com").ctx[:user]
```

```text
[:validate, :save, :grant_admin]
{email: "ann@example.com", admin: true}
[:failure, :validate]
:success
{email: "a@b.c", v: 2}
{email: "a@example.com", v: 2, admin: true}
```

Each class has its own compiled code. Changing what an operation was compiled from
throws that code away, and the next call compiles it again. This covers:

- declaring steps or outputs on it or on an ancestor;
- defining, removing or undefining a step method, also on a parent;
- `include` / `prepend` on the operation class.

These hooks fire while code loads. One change is not detected: a method added later to
a module that is already included. Call `Op.invalidate!` after such a change. See
[compilation](compilation.md).

A subclass can't declare a step its parent already has. Override the method instead:

```ruby
require "octorail"

module Users
  class Create < Octorail::Operation
    step :save
    def save(_ctx) = true
  end

  class Import < Create
    begin
      step :save
    rescue ArgumentError => e
      puts "#{e.class}: #{e.message}"
    end
  end
end
```

```text
ArgumentError: Users::Import: step :save is already declared (step :save)
  declared at tmp/docs-inh/dup.rb:5
```

## Abstract bases and macros

An `abstract!` class holds **tools, not a flow**: shared step and failure-step methods,
wrapper methods, switch deciders, macros, constants and `configure` settings. It can't
declare steps, so every concrete operation shows its whole flow in its own class body.

A **macro** is a class method that calls the DSL. It needs nothing special from the
gem: `extend` a module of macros into the base class, and call them in the operations.

```ruby
require "octorail"

# Macros: class methods that call the DSL and define what they need.
module Macros
  # `authorize! :admin` adds a step checking the current user's role.
  def authorize!(role)
    step :authorize, error: :forbidden
    define_method(:authorize) { |_ctx, current_user:| current_user[:role] == role }
  end
end

class ApplicationOperation < Octorail::Operation
  abstract!
  extend Macros
  configure trace: :off

  # Shared step methods: each operation still lists them in its own flow.
  def log_failure(_ctx, error:, failed_step:) = puts("  failed: #{error} at #{failed_step}")
end

module Orders
  class Cancel < ApplicationOperation
    authorize! :admin
    step :cancel
    failure :log_failure

    def cancel(ctx) = ctx[:cancelled] = true
  end
end

module Users
  class Ban < ApplicationOperation
    authorize! :moderator
    step :ban
    failure :log_failure

    def ban(ctx) = ctx[:banned] = true
  end
end

p Orders::Cancel.call(current_user: { role: :admin }).terminus
p Users::Ban.call(current_user: { role: :admin }).then { [_1.terminus, _1.error] }

begin
  ApplicationOperation.call
rescue Octorail::CompileError => e
  puts "#{e.class}: #{e.message}"
end

begin
  ApplicationOperation.step :authorize
rescue ArgumentError => e
  puts "#{e.class}: #{e.message}"
end

p Octorail.compile_all!.map(&:name)
```

```text
:success
  failed: forbidden at authorize
[:failure, :forbidden]
Octorail::CompileError: ApplicationOperation: is abstract, call an operation that inherits from it
ArgumentError: ApplicationOperation: is abstract (shared methods and macros only), so it can't declare step :authorize; declare it in the operations that inherit from it
["Users::Ban", "Orders::Cancel"]
```

- An abstract base can't be called, and `Octorail.compile_all!` skips it. A base whose
  step methods exist only in subclasses therefore doesn't break boot.
- `abstract!` must come before any declaration. An operation that inherits steps
  can't be abstract. `abstract!` is not inherited: subclasses are concrete.
  `Octorail::Operation` itself is abstract.
- `configure` in a base applies to every operation under it, unless an operation
  overrides it (see [configuration](configuration.md)).

When a step declared by a macro fails, its error shows both places: the line in the
macro and the line in the operation's class body that called the macro.

```ruby
require "octorail"

module Macros
  def authorize!(role)
    step :authorize, error: :forbidden
    define_method(:authorize) { |_ctx, current_user:| current_user[:role] == role }
  end
end

module Orders
  class Cancel < Octorail::Operation
    extend Macros
    authorize! :admin
    step :cancel
    def cancel(_ctx) = true
  end
end

begin
  Orders::Cancel.call
rescue Octorail::MissingKeyError => e
  puts "#{e.class}: #{e.message}"
end
```

```text
Octorail::MissingKeyError: Orders::Cancel: step :authorize requires :current_user, but ctx has no :current_user (ctx keys: none)
  declared at tmp/docs-inh/macro_err.rb:5 (via tmp/docs-inh/macro_err.rb:13)
```

A macro that needs a whole flow rather than one step can declare
`nested SomeOperation` (see [nested](nested.md)).

## Limits

- **No step insertion in subclasses** (`before:` / `after:` / `replace:` / `delete:`).
  A subclass only appends, so the order reads parent first, then child. To change a
  step, override its method. To put shared steps in the middle of a flow, put them in
  an operation and [`nested`](nested.md) it.
- **Step names are unique across the class hierarchy.** Redeclaring a parent's step is
  an `ArgumentError`; override the method instead. The one exception is sibling
  branches of a [switch](switch.md).
- **An abstract base declares no flow** (`step`, `pass`, `failure`, `wrap`, `nested`,
  `switch`, `output` raise `ArgumentError`). Every operation lists its own steps,
  shared ones included. Nothing enforces that an operation includes a shared step:
  there is no `requires_step`.
- **Steps are instance methods only**, not lambdas or callable objects. A macro defines
  a method (`define_method`) together with its step.
- **No instance variables in steps.** One frozen instance serves all calls, so put data
  in ctx (see [steps](steps.md)).
