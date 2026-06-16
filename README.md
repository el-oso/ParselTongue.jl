# ParselTongue.jl

[![CI](https://github.com/el-oso/ParselTongue.jl/actions/workflows/ci.yml/badge.svg)](https://github.com/el-oso/ParselTongue.jl/actions/workflows/ci.yml)
[![Docs (stable)](https://github.com/el-oso/ParselTongue.jl/actions/workflows/Documentation.yml/badge.svg)](https://el-oso.github.io/ParselTongue.jl/stable/)
[![Docs (dev)](https://img.shields.io/badge/docs-dev-blue.svg)](https://el-oso.github.io/ParselTongue.jl/dev/)
[![Julia](https://img.shields.io/badge/Julia-%E2%89%A5%201.12-9558B2.svg?logo=julia&logoColor=white)](https://julialang.org)

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

## Documentation

Full guide, boundary-type reference, and worked examples:
**https://el-oso.github.io/ParselTongue.jl/**

## API

| Macro / function | Purpose |
|------------------|---------|
| `@pyfunc f(a::T)::R = …` | Mark a function for export (emits it normally + records its signature). An optional leading string sets the Python name: `@pyfunc "py_name" f(…) = …`. |
| `@pymodule name begin … end` | Group `@pyfunc` definitions and name the Python module. |
| `@pyhandle T` | Expose an isbits struct `T` as a real Python class; scalar fields become read-only attributes. |
| `@pymethod __repr__ f(p::T)::String = …` | Attach a Python dunder (`__repr__`/`__str__`, `__len__`/`__hash__`/`__bool__`, `__getitem__`, `__eq__`/`__ne__`/`__lt__`/`__le__`/`__gt__`/`__ge__`) to a `@pyhandle` type. |
| `build_extension(path; mod_name, outdir, trim, python, verbose)` | Build just the importable extension `.so` (the surrounding env must provide libjulia). |
| `build_wheel(path; version, mod_name, outdir, python, trim, runtime, slim, abi3, emit_pyproject, verbose)` | Build a self-contained, pip-installable wheel that bundles the Julia runtime. |
| `build_multi_wheel(sources, mod_name; …)` | Aggregate several `@pymodule` files into one wheel (one shared runtime) exposing each as a submodule, so they co-import in one process. |

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

## Installation

ParselTongue depends on
[TypeContracts.jl](https://github.com/el-oso/TypeContracts.jl) (not yet in
the Julia General registry). Install both from GitHub:

```julia
using Pkg
Pkg.develop(url="https://github.com/el-oso/TypeContracts.jl.git")
Pkg.add(url="https://github.com/el-oso/parseltongue.git")
```

## Requirements

- Julia ≥ 1.12 with bundled `juliac` (available via `juliaup`).
- A C compiler: `cc`/`gcc`/`clang` on Linux/macOS; MinGW-w64 `gcc` on Windows.
- `python3` on the build host (any recent CPython 3.x).

## Platform support

| Platform | `build_extension` | `build_wheel` | Compiler required |
|---|---|---|---|
| Linux x86_64 | ✅ | ✅ | `cc` / `gcc` / `clang` |
| macOS arm64, x86_64 | ✅ | ✅ | `cc` (Xcode clang) |
| Windows x86_64 | ✅ | ✅ | MinGW-w64 `gcc` (MSVC not supported) |

**Windows:** install [MSYS2](https://www.msys2.org/) and add
`C:\msys64\mingw64\bin` to `PATH`, or point `JULIA_CC` at your `gcc.exe`.

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

v0.20 — full build pipeline shipping: scalars, strings, N-D numeric arrays,
`ComplexF64`, `Vector{String}`, `Dict{String,V}`, `Vector{UInt8}` (bytes),
`Union{T,Nothing}` (Optional), `NamedTuple`, `Tuple`, real-Python-class opaque
handles (`@pyhandle` — `isinstance`, auto read-only field access, and
`@pymethod __repr__`/`__str__`/`__len__`/`__hash__`/`__bool__`/`__getitem__`/`__eq__`/`__ne__`/`__lt__`/`__le__`/`__gt__`/`__ge__`), custom Python exception
types (`@pyerror`), keyword/default
arguments, arbitrary-signature `PyCallable{Args,Ret}` callbacks, manylinux
tagging, abi3 stable-ABI wheels, shared-runtime wheels, slim bundling,
multi-module wheels (`build_multi_wheel`), `pyproject.toml` generation,
startup benchmarking, and a compiled `pt` CLI binary.
See `examples/`, `app/`, and `ROADMAP.md`.

## pt CLI

Build the `pt` binary once (requires Julia ≥ 1.12 with juliac):

```bash
julia --project=. app/build_app.jl   # → ./pt
```

Then compile extensions without starting a Julia session each time:

```bash
./pt build examples/mathx/mathx.jl --outdir=build
./pt wheel examples/mathx/mathx.jl --outdir=dist --version=0.1.0
./pt bench build/mathx.cpython-*.so --call="mathx.add(1,2)" --n=5
./pt help
```

Or run without compiling (slower — starts Julia each time):

```bash
julia --project=. app/pt.jl build examples/mathx/mathx.jl
```
