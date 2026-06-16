# ParselTongue vs PyO3

Both ParselTongue and [PyO3](https://pyo3.rs) let you call native compiled code
from Python, with full CPython extension semantics, a GIL-releasing calling
convention, and pip-installable wheel output. The core difference is the
implementation language — Julia vs Rust — and the philosophy around how much of
the Python object graph you can reach from native code.

## At a glance

| | **ParselTongue** | **PyO3** |
|---|---|---|
| Implementation language | Julia | Rust |
| Annotation | `@pyfunc` / `@pymodule` | `#[pyfunction]` / `#[pymodule]` |
| Build command | `build_wheel("file.jl")` | `maturin build` |
| Type mapping | Explicit boundary contract | Derive macros + `FromPyObject` / `IntoPyObject` |
| Classes | `@pyhandle` (isbits structs → real Python types; `isinstance`, auto field access, `@pymethod __repr__`/`__str__`) | `#[pyclass]` (full object protocol) |
| Custom exceptions | `@pyerror MyError <: ValueError` | `create_exception!` |
| Python callables | `PyCallable{Args,Ret}` (any scalar signature) | `Py<PyAny>` / `PyCallable` (any signature) |
| GIL release during call | Yes (automatic) | Yes (opt-in with `py.allow_threads`) |
| Stable-ABI wheel (abi3) | Yes (`abi3=true`, floor CPython 3.11) | Yes (`--features abi3`) |
| manylinux tagging | Yes (auto or pinned) | Yes (via `maturin`) |
| Wheel size | ~100 MB (bundled Julia runtime) | ~1–5 MB |
| macOS support | Yes (`-dynamiclib`, `@loader_path`) | Yes |
| Windows support | Yes (MinGW-w64) | Yes |
| Async | No | Yes |
| Free-threading (GIL-free CPython) | No | Experimental |
| Maturity | Early (v0.2x) | Production (v0.22+, widely used) |

## Annotating functions

**PyO3** uses Rust attributes:

```rust
use pyo3::prelude::*;

#[pyfunction]
fn add(a: i64, b: i64) -> i64 {
    a + b
}

#[pymodule]
fn mathx(m: &Bound<'_, PyModule>) -> PyResult<()> {
    m.add_function(wrap_pyfunction!(add, m)?)?;
    Ok(())
}
```

**ParselTongue** uses Julia macros:

```julia
using ParselTongue

@pymodule mathx begin
    @pyfunc add(a::Int64, b::Int64)::Int64 = a + b
end
```

Both approaches produce an equivalent `PyInit_mathx` entry point and a method
table. ParselTongue generates the C shim from the `@pyfunc` metadata; PyO3
generates Rust glue code. The annotation overhead is similar; the host language
(Julia vs Rust) is the dominant ergonomic factor.

## Type system

**PyO3** has a rich, layered type-mapping system. The `FromPyObject` / `IntoPyObject`
derive macros cover Python's built-in types (int, float, str, list, dict, tuple,
bytes, …) automatically. Third-party crates can implement the traits for their
own types. The type-check happens at call time.

**ParselTongue** uses a three-method *boundary contract*: `c_abi_type`, `from_c`,
and `to_c`. Types that don't satisfy the contract are rejected at *build time* with
a clear error, not as a cryptic `juliac --trim` failure. The `@boundary` macro
registers new types without touching ParselTongue's source:

```julia
struct Point2D; x::Float64; y::Float64; end

@boundary Point2D carrier=Int64 begin
    from_c(c) = Point2D(reinterpret(Float32, Int32(c >> 32)),
                        reinterpret(Float32, Int32(c & 0xFFFFFFFF)))
    to_c(p)   = (Int64(reinterpret(Int32, Float32(p.x))) << 32) |
                 Int64(reinterpret(Int32, Float32(p.y)))
end
```

The supported set is narrower than PyO3's today — scalars, `String`,
`Vector{T}`, `Dict{String,V}`, `NamedTuple`, `Union{T,Nothing}`, opaque handles,
and `PyCallable` — but every crossing is explicit and trim-safe.

## Classes and objects

**PyO3** has `#[pyclass]`, which exposes a Rust struct as a full Python object with
`__init__`, dunder methods, properties, inheritance from Python classes, and
reference-counted lifetime management:

```rust
#[pyclass]
struct Counter {
    count: u32,
}

#[pymethods]
impl Counter {
    #[new]
    fn new() -> Self { Counter { count: 0 } }
    fn increment(&mut self) { self.count += 1; }
    #[getter]
    fn value(&self) -> u32 { self.count }
}
```

**ParselTongue** has `@pyhandle`, which is deliberately more restricted:
only `isbitstype` structs (no heap-allocated fields, no Julia GC interaction).
Each handle type becomes a real Python class via `PyType_FromSpec`, so
`isinstance`, `repr`, and tab-completion all work. Julia "methods" are ordinary
`@pyfunc`s that receive and return handles. Mutation is **functional** (return a
new handle); `tp_dealloc` frees the C-heap allocation automatically:

```julia
struct Point; x::Float64; y::Float64; end
@pyhandle Point

@pyfunc make_point(x::Float64, y::Float64)::Point = Point(x, y)
@pyfunc move_x(p::Point, dx::Float64)::Point = Point(p.x + dx, p.y)
@pyfunc norm(p::Point)::Float64 = sqrt(p.x^2 + p.y^2)
```

Each scalar field is automatically exposed as a **read-only Python attribute**
(no annotation needed), and you can override `__repr__` / `__str__` with
`@pymethod`:

```julia
@pymethod __repr__ point_repr(p::Point)::String = "Point($(p.x), $(p.y))"
```

```python
import mymod
p = mymod.make_point(3.0, 4.0)
isinstance(p, mymod.Point)   # True
p.x, p.y                     # (3.0, 4.0)   ← auto field access
repr(p)                      # 'Point(3.0, 4.0)'   ← @pymethod __repr__
```

A `@pymethod` takes exactly one argument — the `self` value of the handle type —
and its return type must match the slot (`String` for `__repr__`/`__str__`). The
underlying Julia function stays callable from Julia. Field access is read-only:
handles are immutable value types, so "mutation" returns a new handle.

The `@pyhandle` restriction exists because GC rooting and arbitrary dunder
protocols require dynamic dispatch that `--trim=safe` would reject. Beyond
`__repr__`/`__str__` and auto field access, general user-defined dunders and
Python inheritance are not supported.

## Error handling

**PyO3** raises Python exceptions via `PyErr` / `PyResult<T>`, with full access to
any built-in or user-defined exception class:

```rust
fn safe_div(a: f64, b: f64) -> PyResult<f64> {
    if b == 0.0 {
        Err(PyValueError::new_err("division by zero"))
    } else {
        Ok(a / b)
    }
}
```

**ParselTongue** propagates Julia `error()` calls as Python `RuntimeError` by
default. Named exception types are registered with `@pyerror`:

```julia
@pyerror DomainError                # → Python mod.DomainError  <: Exception
@pyerror RangeError <: ValueError   # → Python mod.RangeError   <: ValueError

@pyfunc safe_div(a::Float64, b::Float64)::Float64 =
    b == 0.0 ? throw(DomainError(b, "division by zero")) : a / b
```

The error code is packed into an `int32_t` out-parameter and decoded by the C
shim into the right `PyErr_SetString` call. No dynamic Python-object creation
happens inside the trim-safe Julia code.

## GIL management

**PyO3** holds the GIL by default and releases it explicitly:

```rust
#[pyfunction]
fn slow(py: Python<'_>, n: u64) -> u64 {
    py.allow_threads(|| expensive_compute(n))
}
```

**ParselTongue** releases the GIL automatically around every Julia call
(`Py_BEGIN_ALLOW_THREADS` / `Py_END_ALLOW_THREADS` bracket the call in the
generated C shim). There is no opt-in — the GIL is always released, so Julia
functions are always thread-safe with respect to other Python threads.

When calling back into Python from Julia (via `PyCallable`), the GIL is
re-acquired with `PyGILState_Ensure` / `PyGILState_Release`, exactly as PyO3
does via `Python::with_gil`.

## Python callables as arguments

**PyO3** accepts arbitrary Python callables via `Py<PyAny>` and can call them
with any Python-representable argument:

```rust
#[pyfunction]
fn apply(f: &Bound<'_, PyAny>, x: f64) -> PyResult<f64> {
    f.call1((x,))?.extract()
}
```

**ParselTongue** supports `PyCallable{Args, Ret}` with any scalar signature.
The bare name `PyCallable` defaults to `Float64 → Float64`; parameterize it to
declare other signatures:

```julia
@pyfunc apply(f::PyCallable, x::Float64)::Float64 = f(x)            # Float64 → Float64
@pyfunc combine(f::PyCallable{Tuple{Int64,Int64},Int64},           # (Int64, Int64) → Int64
                a::Int64, b::Int64)::Int64 = f(a, b)
```

Internally, `f(a, b, …)` re-acquires the GIL and calls `PyObject_Call` through a
chain of `ccall`s emitted by a `@generated` method — one straight-line, trim-safe
body per concrete signature. Supported argument/return scalar types: `Int8`–`Int64`,
`UInt8`–`UInt64`, `Bool`, `Float32`, `Float64`. Array/string/object arguments and
returns to/from the callback are not yet supported.

## Distribution

| | ParselTongue | PyO3 (via maturin) |
|---|---|---|
| Self-contained wheel | Yes — bundles `libjulia` | Yes — bundles Rust stdlib statically |
| Wheel size | ~100 MB (full Julia runtime) | ~1–5 MB |
| Slim mode | `slim=true` (trims to needed libs, ~38 MB) | N/A |
| Shared runtime | `runtime=:shared` (separate `parseltongue-runtime`) | N/A |
| abi3 | `abi3=true` (CPython ≥ 3.11) | `abi3` feature (CPython ≥ 3.8) |
| manylinux | Auto-detected or `manylinux="2.17"` | Handled by `maturin` |
| macOS | `.dylib` + `@loader_path` rpaths | `.dylib` + `@rpath` |
| Windows | `.pyd`, `os.add_dll_directory` | Yes |

The dominant wheel-size difference comes from the Julia runtime. The trimmed
extension code is small; the Julia stdlib's `__init__` functions fatally
`dlopen` their native backends (OpenBLAS, SuiteSparse, …) at startup even when
unused, so they must all be bundled. Use `slim=true` when your code does not
`using LinearAlgebra` or other stdlib JLLs to drop from ~100 MB to ~38 MB.

## Compile times

**PyO3 / maturin**: Rust's incremental compilation helps on rebuilds, but a
cold `cargo build --release` for a non-trivial extension is 30–120 seconds.

**ParselTongue**: `build_extension` runs `juliac --trim` (10–30 seconds,
depending on the extension's Julia dependencies), then a one-second C compile
and link. Julia's world-age mechanism means there is no incremental mode — each
build starts fresh. For large Julia packages pulled into the trim graph the
build can take minutes.

## When to choose ParselTongue

- Your algorithm is already in Julia and you want to expose it to Python without
  rewriting it.
- You need Julia's ecosystem: `DifferentialEquations.jl`, `Flux.jl`,
  `JuMP.jl`, high-performance numerical code using broadcasting and SIMD.
- You want a zero-boilerplate path: annotate, build, ship. No Rust toolchain,
  no Cargo.toml, no FFI layer to write.
- Build-time type-safety matters: every boundary type is validated at build time
  with a clear error.

## When to choose PyO3

- Your performance-critical code is in Rust, or you want Rust's memory-safety
  guarantees in the extension layer.
- You need to expose **mutable Python objects** (`#[pyclass]`), rich Python
  protocols (`__iter__`, `__len__`, properties), or Python inheritance.
- You need **free-threading** CPython.
- Wheel size matters: a 2 MB PyO3 wheel vs a 100 MB ParselTongue wheel is a
  real deployment difference.
- You need to call Python callbacks with **non-scalar argument types** (arrays,
  strings, objects); ParselTongue's `PyCallable{Args,Ret}` is limited to scalars.
- Your project already has Rust tooling in the CI pipeline.

## Both are good choices when

- You have a compute-intensive kernel (solver, simulation, parser) that you want
  to call from Python with minimal overhead.
- You want GIL-releasing parallelism across Python threads.
- You want stable-ABI (`abi3`) wheels that run on multiple CPython versions.
- You want proper Python exception propagation, not bare `abort()`.
