# Spike: ErrorTypes.jl (Rust-style Result/Option) in trim-safe FFI code

**Branch:** `spike/errortypes` (do **not** merge — evaluation only).
**Question:** can we replace the runtime `try/catch` guards with `Result`/`Option`
(ErrorTypes.jl) to get a *compile-time* check instead of a runtime one?

## What was built
- `Project.toml`: added `ErrorTypes = 0.5` (branch only).
- `spike/errtypes/errtypes_demo.jl`: a `@pymodule` whose `@pyfunc logsqrt` uses an
  **internal** `Result{Float64,Symbol}` pipeline with `@?` propagation (no exceptions),
  consumed at the boundary with `@unwrap_or(..., NaN)`.
- Built with `build_extension` (juliac `--trim=safe`) and called from Python.

## Findings (all mechanics: PASS)
| Question | Result |
|---|---|
| ErrorTypes installs on Julia 1.12 | ✅ v0.5.2 |
| Has a dynamic `__init__` (trim hazard / project policy)? | ✅ **No** `__init__`; concrete parametric structs (`Ok{T}`/`Err{E}`/`Result{O,E}`), no `invokelatest`/`::Any` dispatch |
| Compiles under `juliac --trim=safe` (in the trimmed `.so`) | ✅ **Yes** — `errtypes_demo.cpython-*.so` built |
| Type-stable | ✅ `_pipeline` infers concrete `Result{Float64, Symbol}` (no `Any`) |
| JET-clean | ✅ 0 reports on `_pipeline` |
| Runs correctly | ✅ `logsqrt(4.0)=log√4`; `-1.0`/`2e6` → `NaN` via the `Err` paths |

So ErrorTypes is **usable** in this stack — trim-safe, type-stable, dependency-clean.

## But it does NOT meet the stated objective
The goal was *compile-time* checking replacing the runtime guard. The mechanics work,
yet the premise doesn't hold — confirmed firsthand:

1. **The boundary `try/catch` stays.** The generated `@ccallable` wrapper still wraps the
   body in the trim-safe exception→C-error-code catch. Result handles *only the errors you
   model as `Result`*; arbitrary exceptions (from user code, Base, OOM, bounds) still throw
   and still need the catch. Result is **additive**, not a replacement.
2. **No compile-time enforcement.** Julia has no `#[must_use]`/static exhaustiveness. The
   boundary consumes the `Result` with `@unwrap_or` (a **runtime** check) — `unwrap` would
   throw at runtime, and ignoring a `Result` is silently allowed. ErrorTypes buys
   **explicitness + type-stability**, not the compile-time guarantee Rust gives.
3. **It relocates, not removes, runtime handling.** Internal `throw`→`Result` swaps
   exception control-flow for value control-flow; the *check* is still at runtime.

## Verdict
- **As a compile-time replacement for `try/catch`:** ❌ not achievable in Julia (this spike
  confirms the assessment). The actual static lever is the JET gate (already added to both
  repos) + the `--trim=safe` verifier.
- **As an option for internal error propagation:** 🟡 viable and type-stable. Worth
  considering *only* if the team wants explicit Result-style internal error flow; the cost
  is a new dependency and a mixed idiom (Result internally, exceptions still at the
  boundary). Not recommended purely to "remove a runtime guard," since it doesn't.

Same conclusion would apply to Mexicah's nested `load`/`store!` (internal propagation
only; the FFI catch + the cleanup `finally` both remain).

---

## Real-code conversion: the `PyCallable` call operator (`src/boundary.jl`)

The one genuinely multi-step fallible path in the trimmed runtime. Converted the inline-
`error()` `@generated` operator into a `Result{Ret,Symbol}`-returning core `_pycall` + a
thin operator that unwraps it (still `error()`s on `Err` → the FFI boundary catch turns it
into a Python exception). Builds under `--trim=safe`; all PyCallable paths (apply/combine/
apply_str/apply_vec/bisect + the raise/incompatible-return error paths) behave identically;
unit tests 49/49.

**The genuine win (why this site was worth it):** the original duplicated the *two cleanup
obligations* — `Py_DecRef(args_tup)` + `PyGILState_Release(gstate)` — before each of **4**
`error()` sites. The Result version puts them in **one `finally`**, so:
- a new failure path can't forget the cleanup;
- the GIL is released even if `_py_unbox` itself throws (the original **leaked** it there);
- the failure flow is linear (`return Err(:sym)`) instead of nested cleanup-then-throw.

**Two non-obvious trim-safety costs discovered by building it** (both now commented in the
code, and both are real adoption gotchas):
1. **No splat.** `_pycall(f, args...)` lowers to `Core._apply_iterate` → verifier rejects.
   Must pass the tuple: `_pycall(f, args)` with `args::Tuple`.
2. **Explicit `Result` construction.** Bare `Ok(x)`/`Err(s)` return ErrorTypes'
   `ResultConstructor`; the inferred return is a non-concrete `Union{ResultConstructor…}`
   that `--trim=safe` rejects. A `::Result{Ret,Symbol}` annotation on the `@generated`
   function is **not** enough — each return must be `Result{Ret,Symbol}(Ok{Ret}(x))` /
   `(Err(s))` explicitly.

**Honest verdict for this site:** a modest *readability + cleanup-DRYness + robustness*
win (1 `finally` vs 4 duplicated cleanups). But note what it is and isn't:
- The `try/finally` **stays** — Result does no cleanup; that is finally's job. So this does
  **not** remove the runtime guard; it *reorganizes* error+cleanup around one.
- The operator still `error()`s → the FFI boundary catch is unchanged.
- No compile-time enforcement (Julia limitation, unchanged).
- Adds a dependency to the trimmed image + the two trim gotchas as ongoing footguns.

So: a small net positive *as a code-organization choice for cleanup-coupled multi-step
paths*, **not** the compile-time win originally sought. Whether the cleanup-DRY benefit is
worth a new dependency + the `@generated`/trim gotchas is a judgement call — for a single
operator, probably not; across many such paths, plausibly. Branch left unmerged.
