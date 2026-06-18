# Limitations

ParselTongue is built on the experimental `juliac --trim` (Julia ≥ 1.12). These are
the known constraints, with the reasoning behind each.

## One extension per Python process

Each separately compiled extension embeds its own trimmed Julia system image. That
image's self-initialisation routine runs on `dlopen`; a second such routine in the
same process aborts in `jl_init_threadtls`. This means two independent ParselTongue
`.so` / `.pyd` files cannot coexist in one Python process, **regardless of whether
`runtime=:bundled`, `:shared`, or `:system` is used**:

```python
import mathx     # ok — first .so loads, Julia self-initialises
import strx      # SIGABRT — second .so tries to self-initialise Julia again
```

The fix is always the same: put everything behind **one** compiled extension and
split the API at the Python level:

- **Within one source file:** use [`@pymodule pkg.sub`](/examples/scientific#Submodules)
  to expose submodules (`pkg.linalg`, `pkg.dsp`, …), all backed by one image, so
  `import pkg.linalg` and `import pkg.dsp` coexist fine.
- **Across several source files:** [`build_multi_wheel(["a.jl", "b.jl"], "pkg")`](/reference/api#Building)
  aggregates them into one extension and exposes each file as a submodule
  (`pkg.a`, `pkg.b`) — they import and run together in one process. Function names
  must be unique across the files (they share one C method table).

Removing this limit would require a juliac "link-only" trim mode that emits
`@ccallable` stubs without embedding a self-init — a Julia toolchain change outside
ParselTongue's scope.

## Wheel size (~100 MB)

The trimmed code is tiny, but the Julia runtime's standard-library `__init__`
functions (OpenBLAS, SuiteSparse, …) run at startup and dlopen their backing
libraries even when your code never uses them. Those libraries must therefore be
bundled. Only the system image, the LLVM JIT, and codegen (~500 MB) are excluded,
since a trimmed AOT binary provably never needs them.

Two options already reduce or remove this: `slim=true` vendors only the libraries
reachable via `DT_NEEDED` (~38 MB, safe when your code uses no stdlib JLLs such as
`LinearAlgebra`), and `runtime=:shared` / `runtime=:system` skip vendoring entirely
(~1 MB wheel, with the Julia runtime installed once and shared by every extension).
Slimming the *default* bundle further — by suppressing the unused stdlib inits — is
still a planned optimization.

## Array dtype checking is width-only

An array argument is validated by element **size**, not signedness or kind. A
`float64` buffer passed where `Int64` is expected (both 8 bytes) is not caught and
will be reinterpreted. Match dtypes carefully on the Python side.

## `trim = :safe` rejects dynamic dispatch

This is a feature, not a bug: type-unstable or dynamically-dispatched code in an
exported path fails the build. See [Building](/guide/building#Trim-modes) for the
`:unsafe_warn` escape hatch.

## Rust-style Result/Option types

[ErrorTypes.jl](https://github.com/jakobnissen/ErrorTypes.jl) and similar
`Result{T,E}` / `Option{T}` libraries work fine **inside** Julia helper functions —
the monadic operators (`@?`, `and_then`, `map`) are pure Julia and invisible to the
boundary. The `@pyfunc` that crosses into Python must unwrap to a boundary type:

```julia
using ErrorTypes

_safe_div_impl(a::Float64, b::Float64)::Result{Float64,String} =
    b == 0.0 ? Err("division by zero") : Ok(a / b)

@pyfunc safe_div(a::Float64, b::Float64)::Float64 = begin
    r = _safe_div_impl(a, b)
    is_error(r) ? error(unwrap_error(r)) : unwrap(r)
end
```

From Python's perspective, `Err(...)` and `throw(...)` are identical — both become
Python exceptions. `Union{T,Nothing}` already covers `Option{T}` if you want an
optional return. ErrorTypes.jl is not a ParselTongue dependency and not needed for
any boundary feature; it is purely an ergonomic choice inside your Julia logic.
