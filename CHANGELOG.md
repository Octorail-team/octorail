# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] - 2026-10-28

### Added

- `step`, `pass` and `failure` steps as instance methods, compiled into one plain
  Ruby method on first call, or all at once with `Octorail.compile_all!`.
- Step signatures `(ctx)` or `(ctx, key:, ...)`: keyword arguments are read from
  ctx, and a missing key raises `Octorail::MissingKeyError` before the step runs.
- `error:` on steps; `result.error` and `result.failed_step` on failure.
- `output` declarations: a result exposes only declared keys.
- `fail_fast: true` on `step` and `failure` to end with the `:fail_fast` terminus.
- `failure ..., recover: true` to return to the success track.
- `wrap` to run a group of steps inside a block (transaction, lock, ...).
- `nested` to call another operation with the shared ctx, and `nested_call(ctx)`
  as its entry point.
- `switch` / `on` to pick a branch by a decider method's Symbol;
  an unknown value raises `Octorail::UnknownBranchError`.
- `abstract!` base operations that hold shared methods and settings, but no steps.
- `Octorail.configure` and per-operation `configure`.
- Tracing at `:path` or `:profile` level, `call_traced`, `result.trace`, and
  `exception.octorail_trace`, rendered as a tree (`to_s`) or a hash (`to_h`).
- `to_ruby` to print the generated source.
- Compile-time errors (`Octorail::CompileError` and friends, all `< ScriptError`)
  that point at the declaration line.

[Unreleased]: https://github.com/Octorail-team/octorail/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/Octorail-team/octorail/releases/tag/v1.0.0
