# switch

`switch` picks one of several branches at runtime: for example, one flow for admins and
another for regular users. Each branch is a small railway of its own. After the chosen
branch, the flow continues on the common track. It compiles to a plain `case`, so it
costs nothing at runtime.

## Decider and branches

A **decider** is an instance method that returns the branch key, a Symbol. Its keyword
arguments come from ctx, exactly as a step's (see [steps](steps.md)). Each `on(...)`
declares one branch. A branch can take several keys, and a branch without a block
means "nothing to do for these keys".

```ruby
require "octorail"

module Users
  class Grant < Octorail::Operation
    step :find_user
    switch :role_of do
      on(:admin) { step :grant_all }
      on(:editor, :author) { step :grant_content }
      on(:guest) # nothing to grant
    end
    step :notify

    def find_user(ctx, id:) = ctx[:user] = { id:, role: ctx[:role] }
    def role_of(ctx, user:) = user[:role]&.to_sym
    def grant_all(ctx) = ctx[:granted] = :all
    def grant_content(ctx) = ctx[:granted] = :content
    def notify(ctx) = ctx[:notified] = true
  end
end

%w[admin author guest].each do |role|
  r = Users::Grant.call(id: 1, role:)
  puts "#{role.ljust(7)} #{r.terminus} granted=#{r.ctx[:granted].inspect}"
end

begin
  Users::Grant.call(id: 1, role: "owner")
rescue Octorail::UnknownBranchError => e
  puts "#{e.class}: #{e.message}"
end
```

```text
admin   success granted=:all
author  success granted=:content
guest   success granted=nil
Octorail::UnknownBranchError: Users::Grant: switch :role_of returned :owner, branches: :admin, :editor, :author, :guest
  declared at tmp/docs-switch/basic.rb:6
```

- **The decider returns a branch name, not data.** Keys are Symbols, so convert a
  string or number in the decider (`params[:type].to_sym`).
- To branch on a ctx key, the decider is one line: `def role_of(ctx, role:) = role`.
- To run one operation per branch, use [`nested`](nested.md) inside the branch:
  `on(:admin) { nested Admin::Create }`.
- **A value with no branch raises `Octorail::UnknownBranchError`.** The message names
  the decider, the value, the known branches and where the switch was declared. There
  is no default branch. See [Limits](#limits).

## Failure inside a branch

Outside the switch, it counts as **one step**, like a [`wrap`](wrap.md). When a step in
a branch fails:

1. the failure steps inside the branch that are declared after it run;
2. then the failure steps declared after the `switch` run;
3. the result carries the `error` and `failed_step` of the step that failed.

`fail_fast: true` inside a branch skips both groups of failure steps.

```ruby
require "octorail"

module Payments
  class Pay < Octorail::Operation
    switch :method_of do
      on(:card) do
        step :charge_card, error: :declined
        failure :release_hold
        step :save
      end
      on(:invoice) do
        step :issue_invoice
        step :save
      end
    end
    failure :log_failure

    def method_of(_ctx, method:) = method
    def charge_card(_ctx, card:) = card == "ok"
    def release_hold(_ctx) = puts("  release_hold (inside the branch)")
    def issue_invoice(ctx) = ctx[:invoice] = "INV-1"
    def save(ctx) = ctx[:saved] = true
    def log_failure(_ctx, error:, failed_step:) = puts("  log_failure(#{error}, #{failed_step}) (after the switch)")
  end
end

p Payments::Pay.call(method: :invoice).then { [_1.terminus, _1.ctx[:saved]] }
p Payments::Pay.call(method: :card, card: "bad").then { [_1.terminus, _1.error, _1.failed_step] }
```

```text
[:success, true]
  release_hold (inside the branch)
  log_failure(declined, charge_card) (after the switch)
[:failure, :declined, :charge_card]
```

## The same step in several branches

Step names are unique within an operation, with one exception: **the same step may
appear in different branches of one switch** (`save` above). Branches are mutually
exclusive, so the step still runs at most once per call. It must keep its type in
every branch, because a failure step gets `error:` and `failed_step:` from the failure,
while a step gets them from ctx, and one method can't be compiled as both.

```ruby
require "octorail"

def try
  yield
rescue ArgumentError => e
  puts "#{e.class}: #{e.message}"
end

module Orders; end

try do
  class Orders::Ship < Octorail::Operation
    switch :carrier do
      on(:dhl) { failure :notify }
      on(:ups) { step :notify }
    end
  end
end

try do
  class Orders::Track < Octorail::Operation
    switch(:carrier) { on("dhl") { step :book } }
  end
end

try do
  class Orders::Book < Octorail::Operation
    switch :carrier do
      on(:dhl) { step :book }
      on(:ups, :dhl) { step :book }
    end
  end
end

try do
  class Orders::Label < Octorail::Operation
    switch :carrier do
      step :print
    end
  end
end
```

```text
ArgumentError: Orders::Ship: step :notify is failure :notify in another branch; a step reused across branches keeps its type
  declared at tmp/docs-switch/rules.rb:14 (via tmp/docs-switch/rules.rb:13)
ArgumentError: Orders::Track: switch :carrier: on keys must be Symbols, got "dhl"
ArgumentError: Orders::Book: switch :carrier: on :dhl is already a branch
ArgumentError: Orders::Label: switch :carrier: steps must be inside on(...) branches
```

All of these are raised while the class body loads, not when the operation is called.

## Nesting

Branches can hold anything a flow can hold: [`wrap`](wrap.md), [`nested`](nested.md),
and other switches.

```ruby
require "octorail"

class Tx
  def self.call(_ctx) = yield
end

module Admin
  class Audit < Octorail::Operation
    step :write_audit
    def write_audit(ctx) = (ctx[:log] << :audit)
  end
end

module Orders
  class Refund < Octorail::Operation
    switch :reason_of do
      on(:damaged) do
        wrap Tx do
          step :refund
          switch :amount_of do
            on(:large) { nested Admin::Audit }
            on(:small)
          end
        end
      end
      on(:changed_mind) { step :offer_credit }
    end

    def reason_of(_ctx, reason:) = reason
    def amount_of(_ctx, amount:) = amount > 100 ? :large : :small
    def refund(ctx) = (ctx[:log] << :refund)
    def offer_credit(ctx) = (ctx[:log] << :credit)
  end
end

p Orders::Refund.call(reason: :damaged, amount: 500, log: []).ctx[:log]
p Orders::Refund.call(reason: :damaged, amount: 20, log: []).ctx[:log]
p Orders::Refund.call(reason: :changed_mind, log: []).ctx[:log]
```

```text
[:refund, :audit]
[:refund]
[:credit]
```

In a trace, a switch shows the key the decider returned:
`switch role_of → :admin` (see [tracing](tracing.md)).

## Limits

- **No `otherwise` or default branch.** Give every value the decider can return its own
  `on(...)`; use `on(:guest)` without a block for "nothing to do". A forgotten value is
  then an `UnknownBranchError`, never a silent pass or a disguised business failure.
- **Keys are Symbols only.** The decider returns a branch name; convert data to a
  Symbol in the decider. A key may appear in only one branch.
- **Steps go inside `on(...)`.** A step directly in the `switch` block is an
  `ArgumentError`, and so is `on` outside a `switch`.
- **A step reused across branches keeps its type** (`step` in one branch and `failure`
  in another is an `ArgumentError`). Outside sibling branches, step names stay unique.
- **No jumps between steps** (Trailblazer's `Id()` / `Track()`). The railway is always
  linear. Use `switch` for forks, and `recover:` / `fail_fast:` for leaving the
  failure track (see [fail-fast-and-recover](fail-fast-and-recover.md)).
