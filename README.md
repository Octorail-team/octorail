<p align="center">
  <img src="https://raw.githubusercontent.com/Octorail-team/octorail/main/.github/assets/banner.png" alt="Octorail: railway-oriented operations for Ruby, compiled to plain Ruby" width="100%">
</p>

# Octorail

[![CI](https://img.shields.io/github/actions/workflow/status/Octorail-team/octorail/ci.yml?branch=main&style=flat-square&logo=githubactions&logoColor=white&label=CI)](https://github.com/Octorail-team/octorail/actions/workflows/ci.yml)
[![Coverage](https://img.shields.io/endpoint?url=https%3A%2F%2Fraw.githubusercontent.com%2FOctorail-team%2Foctorail%2Fbadges%2Fcoverage.json&style=flat-square&cacheSeconds=300)](https://github.com/Octorail-team/octorail/actions/workflows/ci.yml)
[![Ruby](https://img.shields.io/badge/ruby-3.3%20%7C%203.4%20%7C%204.0-blue?style=flat-square&logo=ruby&logoColor=white)](https://www.ruby-lang.org)
[![YJIT](https://img.shields.io/badge/YJIT-tested-blue?style=flat-square&logo=ruby&logoColor=white)](https://github.com/Octorail-team/octorail/blob/main/docs/performance.md)
[![Dependencies](https://img.shields.io/badge/dependencies-zero-brightgreen?style=flat-square)](https://github.com/Octorail-team/octorail/blob/main/octorail.gemspec)
[![RuboCop](https://img.shields.io/github/actions/workflow/status/Octorail-team/octorail/lint.yml?branch=main&style=flat-square&logo=rubocop&logoColor=white&label=rubocop)](https://github.com/Octorail-team/octorail/actions/workflows/lint.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue?style=flat-square)](https://github.com/Octorail-team/octorail/blob/main/LICENSE.txt)

Railway-oriented operations for Ruby, in the spirit of Trailblazer, compiled to
plain Ruby. You declare steps; on first use Octorail turns them into one
ordinary method of `if`s and `return`s, so a call costs about what
hand-written code costs and allocates no more.

It is deliberately strict: steps are instance methods, ctx is a Hash, the
railway is linear, and anything ambiguous is an error at load time with the
line that caused it.

Requires Ruby >= 3.3. No dependencies.

```ruby
gem "octorail"
```

## Example

```ruby
class Orders::Checkout < Octorail::Operation
  output :order

  nested Orders::Validate
  wrap :transaction do
    step :create_order
    nested Payments::Charge
  end
  switch :delivery_for do
    on(:pickup)
    on(:courier) { step :book_courier }
  end
  pass :send_receipt
  failure :log_failure

  def transaction(_ctx, &) = ActiveRecord::Base.transaction(requires_new: true) { yield || raise(ActiveRecord::Rollback) }
  def create_order(ctx, user:, total:) = ctx[:order] = user.orders.create!(total:)
  def delivery_for(_ctx, delivery: :courier) = delivery
  def book_courier(ctx, order:, address:) = Couriers.book(order, address)
  def send_receipt(_ctx, order:) = ReceiptMailer.with(order:).deliver_later
  def log_failure(_ctx, error:, failed_step:) = Rails.logger.warn("checkout: #{error} at #{failed_step}")
end

result = Orders::Checkout.call(user:, total: 42, address: "Kyiv")
result.success?     # => false
result.error        # => :declined      (from inside Payments::Charge)
result.failed_step  # => :charge

case result
in { success: true, order: } then redirect_to order
in { error: :declined }      then render :card_declined
end
```

And when you need to know why:

```text
Orders::Checkout  4.874 ms
├── ✓ nested Orders::Validate  0.636 ms
│   └── ✓ check  0.002 ms
├── wrap transaction → false  4.176 ms
│   ├── ✓ create_order  0.001 ms
│   └── ✗ nested Payments::Charge  4.171 ms
│       ├── ✓ authorize  0.001 ms
│       └── ✗ charge  2.993 ms
├── · failure log_failure  0.001 ms
└── failure error=:declined failed_step=:charge
```

## What you get

- `step` / `pass` / `failure`, with keyword arguments read from ctx and a
  clear error when a required key is missing.
- `wrap` for transactions, locks, retries; `nested` to compose operations;
  `switch` to branch on a value.
- `fail_fast:` and `failure ..., recover: true` to leave or rejoin the success track.
- Results with `error`, `failed_step`, declared outputs and pattern matching.
- Tracing on demand (`call_traced`), per operation or globally, attached to
  results and to exceptions.
- Errors at load time that point at the declaration line.

## Speed

Ten trivial steps, Ruby 4.0 with YJIT: Octorail 416 ns, a hand-written PORO
425 ns, Yaso 897 ns, Decouplio 1.1 µs, Trailblazer 25.2 µs. Allocations equal
the PORO's. Averaged over 36 benchmarks (3 Rubies, with and without YJIT):
1.7× faster than Yaso, 1.9× than Decouplio, 38× than Trailblazer. Full tables
and caveats in [performance](https://github.com/Octorail-team/octorail/blob/main/docs/performance.md).

## Documentation

- [Guide](https://github.com/Octorail-team/octorail/blob/main/docs/guide.md): one operation built end to end
- [Steps](https://github.com/Octorail-team/octorail/blob/main/docs/steps.md) · [Result](https://github.com/Octorail-team/octorail/blob/main/docs/result.md) ·
  [Fail fast and recover](https://github.com/Octorail-team/octorail/blob/main/docs/fail-fast-and-recover.md)
- [Wrap](https://github.com/Octorail-team/octorail/blob/main/docs/wrap.md) · [Nested](https://github.com/Octorail-team/octorail/blob/main/docs/nested.md) · [Switch](https://github.com/Octorail-team/octorail/blob/main/docs/switch.md) ·
  [Inheritance and macros](https://github.com/Octorail-team/octorail/blob/main/docs/inheritance.md)
- [Compilation](https://github.com/Octorail-team/octorail/blob/main/docs/compilation.md) · [Tracing](https://github.com/Octorail-team/octorail/blob/main/docs/tracing.md) ·
  [Configuration](https://github.com/Octorail-team/octorail/blob/main/docs/configuration.md) · [Errors](https://github.com/Octorail-team/octorail/blob/main/docs/errors.md)
- [Testing](https://github.com/Octorail-team/octorail/blob/main/docs/testing.md) · [Performance](https://github.com/Octorail-team/octorail/blob/main/docs/performance.md)

Each page ends with **Limits**: what the gem forbids around that feature, why,
and what to do instead.

## Rails

Octorail itself doesn't depend on Rails. To compile every operation at boot, so
a broken one fails the deploy instead of the first request, add an initializer:

```ruby
# config/initializers/octorail.rb
Rails.application.config.after_initialize do
  Octorail.compile_all! if Rails.configuration.eager_load
end
```

## Development

Everything runs in Docker; no local Ruby needed.

```sh
make build              # build images for Ruby 3.3 / 3.4 / 4.0
make test               # rspec on Ruby 3.3
make test RUBY=ruby40   # rspec on a specific Ruby
make test-all           # rspec on every supported Ruby
make lint               # rubocop
make bench RUBY=ruby34  # benchmarks against Yaso, Decouplio, Trailblazer
make console            # IRB with the gem loaded
```

## License

MIT, see [LICENSE.txt](https://github.com/Octorail-team/octorail/blob/main/LICENSE.txt).
