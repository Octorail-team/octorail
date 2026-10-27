# Configuration

Settings change how operations are compiled. Set them globally with `Octorail.configure`, or per
operation with `configure`. The most specific value wins: the operation, then its ancestors, then
the global value, then the default.

There is one setting so far: `trace` (see [tracing](tracing.md)). New settings are added only when
there is something to configure.

| setting | values | default |
|---|---|---|
| `trace` | `:off`, `:path`, `:profile` | `:off` |

## Global and per operation

```ruby
Octorail.configure do |config|
  config.trace = :off
end

class ApplicationOperation < Octorail::Operation
  abstract!
end

module Payments
  class Base < ApplicationOperation
    abstract!
    configure trace: :path # every payment operation is traced
  end

  class Charge < Base
    step :charge
    def charge(_ctx) = true
  end

  class Refund < Base
    configure trace: :off # except this one
    step :refund
    def refund(_ctx) = true
  end
end

module Users
  class Create < ApplicationOperation
    step :persist
    def persist(_ctx) = true
  end
end

p Payments::Charge.setting(:trace)
p Payments::Refund.setting(:trace)
p Users::Create.setting(:trace)
p Payments::Charge.call.trace.class
p Users::Create.call.trace
```

```text
:path
:off
:off
Octorail::Trace
nil
```

- **`configure` is inherited.** A subclass can override it again.
- **It is allowed in an `abstract!` base**, because it is a setting, not flow (see [inheritance](inheritance.md)).
- **`Op.setting(:trace)` returns the value the operation ends up with.**

## Where to put it

- **Plain Ruby:** call `Octorail.configure` once at boot, before the first operation call.
- **Rails:** put it in `config/initializers/octorail.rb`. Branch on `Rails.env` there if environments differ, for example `config.trace = :path if Rails.env.staging?`. There are no `config.octorail.*` settings per environment.

The order of configuration and class loading doesn't matter. Changing a setting drops compiled code, and each operation recompiles with the new value on its next call:

```ruby
Octorail.config.trace = :profile
p Users::Create.compiled?
p Users::Create.call.trace.level
```

```text
false
:profile
```

## Invalid values

Unknown keys and invalid values raise right where they are written:

```ruby
Octorail.config.trace = true
Octorail.configure { |config| config.trcae = :path }
Class.new(Octorail::Operation) { configure trcae: :path }
Class.new(Octorail::Operation) { configure trace: :all }
```

```text
ArgumentError: Octorail.config: trace must be one of :off, :path, :profile, got true
NoMethodError: undefined method 'trcae=' for an instance of Octorail::Config
ArgumentError: #<Class:0x0000ffff6b1974e8>: configure: unknown setting :trcae, allowed: :trace
ArgumentError: #<Class:0x0000ffff6b196fe8>: configure: trace must be one of :off, :path, :profile, got :all
```

## Limits

- **Settings are boot-time.** Changing them on a live process under load is not supported. Recompiling swaps methods, and a call running at that moment may fail. This is the same limit as code reload (see [compilation](compilation.md)). To trace one call, use `call_traced` instead of flipping the setting.
- **Symbols only for `trace`.** `true` / `false` are rejected, so the level is always explicit.
- **No per-environment settings in the gem.** Branch on `Rails.env` (or `ENV`) inside your initializer.
