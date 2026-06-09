# ParselTongue.jl

Write a Python extension in plain Julia. Annotate functions with one macro, run
one build command, get an importable module or a pip-installable wheel — no Rust,
no PyO3, no hand-written C.

ParselTongue compiles your Julia with **`juliac --trim`** (Julia ≥ 1.12) into a
small C-ABI shared library, then generates a native CPython extension (`PyInit_…`)
around it and, optionally, bundles the Julia runtime into a self-contained wheel.

```julia
# mathx.jl
using ParselTongue

@pymodule mathx begin
    @pyfunc add(a::Int64, b::Int64)::Int64        = a + b
    @pyfunc greet(name::String)::String           = "Hello, " * name * "!"
    @pyfunc sum_f64(xs::Vector{Float64})::Float64 = sum(xs)
end
```

```julia
using ParselTongue
build_wheel("mathx.jl")          # -> dist/mathx-0.1.0-cp3xx-…-linux_x86_64.whl
```

```console
$ pip install mathx-0.1.0-*.whl   # no Julia needed on this machine
$ python -c "import mathx; print(mathx.add(40,2), mathx.greet('World'))"
42 Hello, World!
```

## API

| Macro / function | Purpose |
|------------------|---------|
| `@pyfunc f(a::T)::R = …` | Mark a function for export (emits it normally + records its signature). An optional leading string sets the Python name: `@pyfunc "py_name" f(…) = …`. |
| `@pymodule name begin … end` | Group `@pyfunc` definitions and name the Python module. |
| `build_extension(path; mod_name, outdir, trim, python, verbose)` | Build just the importable extension `.so` (the surrounding env must provide libjulia). |
| `build_wheel(path; version, mod_name, outdir, python, trim, verbose)` | Build a self-contained, pip-installable wheel that bundles the Julia runtime. |

`trim` is `:safe` (default — errors at build on dynamic dispatch), `:unsafe`, or
`:unsafe_warn`.

## Boundary types (v1)

Arguments and return values must be **boundary types**, lowered to a C-ABI carrier:

| Julia | Python | Notes |
|-------|--------|-------|
| `Int8/16/32/64`, `UInt8/16/32/64`, `Bool` | `int` / `bool` | |
| `Float32`, `Float64` | `float` | |
| `String` | `str` | UTF-8; returns are copied into a Python `str`. |
| `Vector{T}` (numeric `T`) | buffer in, `numpy.ndarray` out | Zero-copy input from any buffer (numpy, `array.array`, `memoryview`); returns become `np.ndarray` when numpy is importable, else a `memoryview`. |

numpy is **never a build-time dependency** — it is resolved at runtime and listed
as an optional extra. A non-boundary type in a signature is rejected at build time
with a clear message (not a cryptic trim error), via a `TypeContracts` contract.

## Requirements

- Julia ≥ 1.12 with bundled `juliac` (e.g. via `juliaup`).
- A C compiler (`cc`/`gcc`/`clang`) and `python3` with development headers.

## Known limitations (v1)

- **One ParselTongue extension per Python process.** Each wheel embeds its own
  libjulia; importing two such extensions in the same process aborts (two Julia
  runtimes cannot coexist). A shared-runtime mode is future work.
- **Wheel size ≈ 100 MB.** The trimmed code is tiny, but the Julia runtime's
  stdlib `__init__`s (OpenBLAS, etc.) run at startup and require their libraries,
  so the support libraries must be bundled (only the system image, LLVM, and
  codegen — ~500 MB — are excluded). Shrinking this needs suppression of unused
  stdlib inits.
- **Arrays are 1-D.** N-D support needs the column/row-major story resolved.
- **Array dtype check** validates element size, not signedness/kind (e.g. an
  `int64` buffer passed where `Float64` is expected is not caught — same width).

## How it works

```
@pyfunc  ─►  generated Base.@ccallable wrappers (Julia, C-ABI carriers)
         ─►  juliac --output-lib --experimental --trim=safe  ─►  img.a (trimmed)
         ─►  generated _<mod>module.c  (PyInit + PyObject↔C marshalling)
         ─►  cc -shared: shim + img.a + libjulia  ─►  <mod>.<ext>.so
         ─►  wheel: __init__.py + .so + julia/ runtime  (rpath $ORIGIN/julia/lib…)
```

The C shim and Julia wrappers are generated from ParselTongue's own macro
metadata. The boundary type system reuses
[TypeContracts.jl](../TypeContracts) for compile-time validation.

## Status

v0.1 — milestones M1–M6 complete: scalars, strings, and 1-D numeric arrays build
end-to-end into importable, self-contained wheels. See `examples/` (`mathx`,
`strx`, `arrx`) and `test/`.
