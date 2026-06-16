# Limitations (v1)

ParselTongue v0.1 is built on the experimental `juliac --trim`. These are the
known constraints, with the reasoning behind each.

## One extension per Python process

Each wheel embeds its own copy of `libjulia`. Importing **two** ParselTongue
extensions into the same Python process aborts the process — two Julia runtimes
cannot coexist.

```python
import mathx     # ok
import strx      # abort: a second libjulia re-runs jl_init and aborts the process
```

Each separately compiled extension embeds its own trimmed system image and runs
`jl_init` on first use; a second one aborts in `jl_init_threadtls`, even if both
link the same `libjulia`. The fix is to keep everything behind **one** compiled
extension and split the API at the Python level:

- **Within one source file:** use [`@pymodule pkg.sub`](/examples/scientific#Submodules)
  to expose submodules (`pkg.linalg`, `pkg.dsp`, …), all backed by one image, so
  `import pkg.linalg` and `import pkg.dsp` coexist fine.
- **Across several source files:** [`build_multi_wheel(["a.jl", "b.jl"], "pkg")`](/reference/api#Building)
  aggregates them into one extension and exposes each file as a submodule
  (`pkg.a`, `pkg.b`) — they import and run together in one process. Function names
  must be unique across the files (they share one C method table).

## Wheel size (~100 MB)

The trimmed code is tiny, but the Julia runtime's standard-library `__init__`
functions (OpenBLAS, SuiteSparse, …) run at startup and dlopen their backing
libraries even when your code never uses them. Those libraries must therefore be
bundled. Only the system image, the LLVM JIT, and codegen (~500 MB) are excluded,
since a trimmed AOT binary provably never needs them.

Shrinking the wheel further requires suppressing the unused stdlib inits — a
planned optimization.

## Array dtype checking is width-only

An array argument is validated by element **size**, not signedness or kind. A
`float64` buffer passed where `Int64` is expected (both 8 bytes) is not caught and
will be reinterpreted. Match dtypes carefully on the Python side.

## `trim = :safe` rejects dynamic dispatch

This is a feature, not a bug: type-unstable or dynamically-dispatched code in an
exported path fails the build. See [Building](/guide/building#Trim-modes) for the
`:unsafe_warn` escape hatch.
