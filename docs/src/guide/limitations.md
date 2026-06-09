# Limitations (v1)

ParselTongue v0.1 is built on the experimental `juliac --trim`. These are the
known constraints, with the reasoning behind each.

## One extension per Python process

Each wheel embeds its own copy of `libjulia`. Importing **two** ParselTongue
extensions into the same Python process aborts the process — two Julia runtimes
cannot coexist.

```python
import mathx     # ok
import strx      # abort: a second libjulia is loaded
```

Build the functions you need to use together into a **single** module. A
shared-runtime mode (one libjulia across extensions) is future work.

## Wheel size (~100 MB)

The trimmed code is tiny, but the Julia runtime's standard-library `__init__`
functions (OpenBLAS, SuiteSparse, …) run at startup and dlopen their backing
libraries even when your code never uses them. Those libraries must therefore be
bundled. Only the system image, the LLVM JIT, and codegen (~500 MB) are excluded,
since a trimmed AOT binary provably never needs them.

Shrinking the wheel further requires suppressing the unused stdlib inits — a
planned optimization.

## Arrays are 1-D

`Vector{T}` for numeric `T` is supported zero-copy. N-dimensional arrays are not
yet exposed, because the column-major (Julia) vs. row-major (NumPy default)
layout needs an explicit, unsurprising convention first.

## Array dtype checking is width-only

An array argument is validated by element **size**, not signedness or kind. A
`float64` buffer passed where `Int64` is expected (both 8 bytes) is not caught and
will be reinterpreted. Match dtypes carefully on the Python side.

## `trim = :safe` rejects dynamic dispatch

This is a feature, not a bug: type-unstable or dynamically-dispatched code in an
exported path fails the build. See [Building](/guide/building#Trim-modes) for the
`:unsafe_warn` escape hatch.
