# Performance

Octorail compiles each operation into one plain Ruby method, so a call costs about as much as the
same code written by hand. This page explains where that speed comes from, shows the benchmark
against other railway gems, and says when it matters.

## Why it's fast

- **Compiled code, no DSL at runtime.**
  - Steps become direct method calls with `unless` / `return` (see `to_ruby` in [compilation](compilation.md)).
  - A call doesn't walk a step list, build per-step state or dispatch through callables.
  - Keyword arguments are read from ctx in generated code, so steps don't need a `**` splat.
- **One frozen instance per operation.** Calls don't allocate an operation object, and the instance is thread-safe without locks.
- **Allocations equal hand-written code.** A call allocates the ctx Hash (Ruby's own copy of `**input`) and the `Result`. That is the same count as the plain-Ruby baseline in every scenario below.
- **Tracing costs nothing when off.** It is a separate compiled variant (see [tracing](tracing.md)).

## Benchmark

`bench/` runs the same operations written idiomatically for every library:

- **PORO** is a hand-written class, unrolled like Octorail's generated code, with a frozen instance and a Struct result. It is the floor.
- **Scenarios:**
  - `CreateUser`: validate → build → persist → pass notify, with a failure step.
  - 10 trivial steps.
  - A no-op wrapper around 2 steps.
  - A nested operation: success, and failure inside.
- **Method:** each cell is benchmark-ips (1 s warmup, 3 s run), time per call. `· N` is objects allocated per call.
- **Environment:** run on Docker, aarch64.

### Ruby 4.0

| scenario | PORO | **Octorail** | Yaso | Decouplio | Trailblazer |
|---|---|---|---|---|---|
| **YJIT** | | | | | |
| CreateUser, success | 187 ns · 2 | **212 ns · 2** | 541 ns · 6 | 428 ns · 6 | 12.6 µs · 190 |
| CreateUser, failure | 211 ns · 4 | **200 ns · 4** | 335 ns · 5 | 335 ns · 8 | 9.0 µs · 135 |
| 10 steps | 425 ns · 2 | **416 ns · 2** | 897 ns · 2 | 1.1 µs · 6 | 25.2 µs · 347 |
| wrap | 211 ns · 2 | **230 ns · 2** | 795 ns · 8 | 501 ns · 6 | 17.3 µs · 242 |
| nested, success | 267 ns · 3 | **274 ns · 3** | 630 ns · 7 | 584 ns · 8 | 15.6 µs · 237 |
| nested, failure | 314 ns · 5 | **248 ns · 5** | 408 ns · 6 | 498 ns · 10 | 12.7 µs · 182 |
| **no JIT** | | | | | |
| CreateUser, success | 300 ns | **448 ns** | 888 ns | 999 ns | 18.2 µs |
| CreateUser, failure | 321 ns | **351 ns** | 609 ns | 703 ns | 13.3 µs |
| 10 steps | 528 ns | **689 ns** | 1.5 µs | 1.8 µs | 37.1 µs |
| wrap | 353 ns | **512 ns** | 1.3 µs | 1.2 µs | 24.7 µs |
| nested, success | 414 ns | **617 ns** | 1.1 µs | 1.4 µs | 23.1 µs |
| nested, failure | 429 ns | **525 ns** | 830 ns | 1.1 µs | 17.7 µs |

### Ruby 3.4

| scenario | PORO | **Octorail** | Yaso | Decouplio | Trailblazer |
|---|---|---|---|---|---|
| **YJIT** | | | | | |
| CreateUser, success | 254 ns · 2 | **438 ns · 2** | 610 ns · 6 | 736 ns · 6 | 15.9 µs · 191 |
| CreateUser, failure | 318 ns · 4 | **420 ns · 4** | 461 ns · 5 | 666 ns · 8 | 11.5 µs · 136 |
| 10 steps | 484 ns · 2 | **733 ns · 2** | 1.0 µs · 2 | 1.2 µs · 6 | 30.0 µs · 348 |
| wrap | 260 ns · 2 | **437 ns · 2** | 998 ns · 8 | 786 ns · 6 | 21.1 µs · 243 |
| nested, success | 378 ns · 3 | **668 ns · 3** | 820 ns · 7 | 1.0 µs · 8 | 19.6 µs · 238 |
| nested, failure | 426 ns · 5 | **666 ns · 5** | 715 ns · 6 | 1.2 µs · 10 | 16.6 µs · 183 |
| **no JIT** | | | | | |
| CreateUser, success | 374 ns | **654 ns** | 927 ns | 1.3 µs | 21.5 µs |
| CreateUser, failure | 423 ns | **552 ns** | 680 ns | 966 ns | 14.5 µs |
| 10 steps | 568 ns | **885 ns** | 1.5 µs | 2.0 µs | 39.0 µs |
| wrap | 418 ns | **773 ns** | 1.3 µs | 1.5 µs | 26.9 µs |
| nested, success | 510 ns | **1.1 µs** | 1.2 µs | 1.9 µs | 25.9 µs |
| nested, failure | 542 ns | **1.0 µs** | 993 ns | 1.5 µs | 20.4 µs |

### Ruby 3.3

| scenario | PORO | **Octorail** | Yaso | Decouplio | Trailblazer |
|---|---|---|---|---|---|
| **YJIT** | | | | | |
| CreateUser, success | 226 ns · 2 | **326 ns · 2** | 798 ns · 10 | 651 ns · 7 | 15.7 µs · 224 |
| CreateUser, failure | 292 ns · 4 | **392 ns · 4** | 409 ns · 7 | 595 ns · 9 | 9.6 µs · 157 |
| 10 steps | 399 ns · 2 | **590 ns · 2** | 1.2 µs · 12 | 1.4 µs · 7 | 32.1 µs · 418 |
| wrap | 268 ns · 3 | **414 ns · 3** | 1.0 µs · 13 | 718 ns · 7 | 20.2 µs · 284 |
| nested, success | 351 ns · 3 | **553 ns · 3** | 813 ns · 11 | 932 ns · 9 | 18.9 µs · 277 |
| nested, failure | 389 ns · 5 | **521 ns · 5** | 574 ns · 8 | 887 ns · 11 | 14.9 µs · 210 |
| **no JIT** | | | | | |
| CreateUser, success | 370 ns | **723 ns** | 1.2 µs | 1.1 µs | 20.5 µs |
| CreateUser, failure | 393 ns | **469 ns** | 663 ns | 827 ns | 14.0 µs |
| 10 steps | 570 ns | **833 ns** | 1.8 µs | 1.9 µs | 39.2 µs |
| wrap | 391 ns | **692 ns** | 1.3 µs | 1.3 µs | 26.0 µs |
| nested, success | 456 ns | **873 ns** | 1.2 µs | 1.6 µs | 25.1 µs |
| nested, failure | 476 ns | **794 ns** | 925 ns | 1.3 µs | 19.1 µs |

Allocations without JIT are the same as with YJIT.

### Summary over all 36 cells

| Octorail compared with | average (geometric mean) | range |
|---|---|---|
| Yaso | 1.66× faster | 0.99× (a tie) … 3.5× |
| Decouplio | 1.9× faster | 1.5× … 2.6× |
| Trailblazer | 38× faster | 20× … 75× |
| hand-written PORO | 1.4× slower | on Ruby 4.0 + YJIT about equal |

- **benchmark-ips varies ±5–15% on a busy machine.** The "10 steps" cell on Ruby 3.4 + YJIT (733 ns) is such an outlier: an interleaved best-of-15 run of the same operation gives 377 ns.
- **Octorail can beat PORO** in two failure scenarios on Ruby 4.0. The PORO baseline allocates a Struct result, while Octorail's `Result` is a plain class.

## Running it

```sh
make bench RUBY=ruby34         # with YJIT
make bench-nojit RUBY=ruby34   # without JIT
```

`RUBY` is one of `ruby33`, `ruby34`, `ruby40`. To run only some scenarios, pass `BENCH_ONLY`
(matched against scenario titles): `make bench RUBY=ruby34 BENCH_ONLY=nested`.

## When it matters

Rarely on its own. The difference between Octorail and Yaso is hundreds of nanoseconds per call.
A request that touches a database or an HTTP API spends milliseconds there. Against Trailblazer the
gap is 10–40 µs and 130–420 allocations per call. That adds up in operations called in loops, in
background jobs that process many records, and in GC pressure on busy servers. Choose Octorail for
its strictness first. The speed means you never have to avoid an operation for performance reasons.

## Limits

- **Steps are instance methods only, no lambdas or callable objects.** This is what lets the compiler emit direct calls (see [steps](steps.md)).
- **The railway is linear: no jumps by step id, no custom wiring.** Generated code stays plain `if` / `return`. Jumps in any direction would need a state machine, measured at +13–16% with YJIT and +32–40% without (see [fail-fast-and-recover](fail-fast-and-recover.md) and [switch](switch.md) for what to use instead).
- **No `**` in step signatures.** The compiler reads ctx keys from explicit keyword arguments; `**` would force passing the whole ctx (see [steps](steps.md)).
- **Tracing has a real cost when on**, roughly 1–3 µs per 10 steps (see [tracing](tracing.md)). Leave it `:off` in hot paths.
