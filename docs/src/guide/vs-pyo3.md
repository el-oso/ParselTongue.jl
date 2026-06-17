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
| Build CLI | `pt wheel file.jl` (or `build_wheel("file.jl")`) | `maturin build` |
| Type mapping | Explicit boundary contract | Derive macros + `FromPyObject` / `IntoPyObject` |
| Classes | `@pyhandle` (isbits) + `@pymutable` (heap fields, GC registry); `isinstance`, mutable fields, ~25 dunders incl. numeric (mixed-type) + iterator (`__next__`), bound named methods, `@pyproperty`, context managers, opt-in `subclass=` (Python subclassing) | `#[pyclass]` (full object protocol incl. instance `dict`, `extends=` native inheritance) |
| Custom exceptions | `@pyerror MyError <: ValueError` | `create_exception!` |
| Python callables | `PyCallable{Args,Ret}` (any scalar signature) | `Py<PyAny>` / `PyCallable` (any signature) |
| GIL release during call | Yes (automatic) | Yes (opt-in with `py.allow_threads`) |
| Stable-ABI wheel (abi3) | Yes (`abi3=true`, floor CPython 3.11) | Yes (`--features abi3`) |
| manylinux tagging | Yes (auto or pinned) | Yes (via `maturin`) |
| Emitted wheel size | ~1 MB with a shared/system runtime (Julia installed once); ~100 MB fully self-contained | ~1–5 MB (self-contained) |
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

**ParselTongue** has `@pyhandle` for `isbitstype` structs (all-scalar fields, no
heap allocation, no Julia GC interaction). Each handle type becomes a real Python
class via `PyType_FromSpec`; `isinstance`, `repr`, and tab-completion all work.
`tp_dealloc` frees the C-heap copy automatically. The supported dunder surface is
broad:

```julia
struct Point; x::Float64; y::Float64; end
@pyhandle Point mutable=true          # mutable=true enables p.x = ... in Python

@pymethod __new__      pt_new(x::Float64, y::Float64)::Point = Point(x, y)
@pymethod __repr__     pt_repr(p::Point)::String = "Point($(p.x), $(p.y))"
@pymethod __len__      pt_len(p::Point)::Int64   = 2
@pymethod __getitem__  pt_get(p::Point, i::Int64)::Float64 = i == 0 ? p.x : p.y
@pymethod __setitem__  pt_set(p::Point, i::Int64, v::Float64)::Point =
    i == 0 ? Point(v, p.y) : Point(p.x, v)   # write-back via unsafe_store!
@pymethod __contains__ pt_has(p::Point, v::Float64)::Bool = p.x == v || p.y == v
@pymethod __iter__     pt_iter(p::Point)::Point  = p   # Py_INCREF; return self
@pymethod __eq__       pt_eq(p::Point, q::Point)::Bool = p.x == q.x && p.y == q.y
@pymethod __lt__       pt_lt(p::Point, q::Point)::Bool =
    p.x^2 + p.y^2 < q.x^2 + q.y^2

@pyproperty Point norm::Float64 (p -> sqrt(p.x^2 + p.y^2))
```

```python
import mymod
p = mymod.Point(3.0, 4.0)
isinstance(p, mymod.Point)   # True
p.x, p.y                     # (3.0, 4.0)   ← auto field access
p.norm                       # 5.0           ← @pyproperty
p.x = 0.0                    # ← mutable=true
p[1] = 9.0                   # ← __setitem__ write-back
3.0 in p                     # ← __contains__
p < mymod.Point(10.0, 0.0)   # ← __lt__  (__gt__ via Python reflection)
```

For context managers, `__enter__` / `__exit__` go in the `Py_tp_methods` table
(not a type slot):

```julia
@pymethod __enter__ cm_enter(c::Conn)::Conn = c
@pymethod __exit__  cm_exit(c::Conn)::Bool  = (close!(c); false)
```

Callable handles (`__call__`), numeric operators (`__add__`, `__mul__`, `__neg__`,
`__abs__`, …, mapped to the `Py_nb_*` slots), and comparisons round out the
protocol.

`@pyhandle` itself is limited to `isbitstype` structs (no `String`/`Vector`
fields). For mutable objects with heap fields, use **`@pymutable`**, which backs
each instance with a per-type Julia GC registry (`Dict{Int64, T}`) — the Python
object holds only an id, and `from_c` returns the *live* Julia object so methods
mutate it in place:

```julia
mutable struct Counter
    count::Int64
    name::String        # heap field — not allowed in @pyhandle
end
@pymutable Counter

@pymethod __new__ counter_new(name::String)::Counter = Counter(0, name)
# A module-level @pyfunc mutates the live object; the change persists.
@pyfunc bump(c::Counter)::Int64 = (c.count += 1; c.count)
```

Stateful iterators are the canonical use: `@pymethod __next__` returns
`Union{V, Nothing}` (`nothing` → `StopIteration`) and advances state in place, so
`for`, `list`, `sum`, and comprehensions all work:

```julia
mutable struct CountUp; cur::Int64; stop::Int64; end
@pymutable CountUp
@pymethod __iter__ cu_iter(c::CountUp)::CountUp = c
@pymethod __next__ cu_next(c::CountUp)::Union{Int64,Nothing} =
    c.cur >= c.stop ? nothing : (c.cur += 1; c.cur - 1)
```

The registry is a concretely-typed global, so `to_c`/`from_c`/dealloc stay
trim-safe.

### Bound methods, mixed-type operators, and subclassing

A `@pymethod` with a **plain (non-dunder) name** becomes a bound instance method
(`obj.method(args)`), registered in the type's method table:

```julia
@pymethod bump!(c::Counter)::Int64 = (c.count += 1; c.count)   # c.bump()
@pymethod scaled(v::Vec2, k::Float64)::Vec2 = Vec2(v.x*k, v.y*k) # v.scaled(2.0)
```

Numeric operators support **mixed operand types** and reflected forms, so both
`vec * 2.0` and `2.0 * vec` work (the C number slot dispatches on operand types;
a non-matching operand yields `NotImplemented` so Python falls back):

```julia
@pymethod __truediv__ divk(p::Vec2, k::Float64)::Vec2 = Vec2(p.x/k, p.y/k)  # p / 2.0
@pymethod __rmul__    rscale(p::Vec2, k::Float64)::Vec2 = Vec2(p.x*k, p.y*k) # 2.0 * p
```

Types opt into **Python subclassing** with a flag mirroring PyO3's
`#[pyclass(subclass)]` (default off):

```julia
@pyhandle Vec2 subclass=true       # `class MyVec(Vec2): ...` in Python
@pymutable Counter subclass=true   # works for mutable types too
```

`subclass=true` adds `Py_TPFLAGS_BASETYPE` and a subclass-aware `tp_new`
(abi3-safe). A pure-Python subclass can add methods, `@property`, and override
dunders, inheriting the constructor, fields, and bound methods.

Remaining gaps vs `#[pyclass]`:

- **`#[pyclass(dict)]`** — a per-instance `__dict__` so subclass *instances* can hold
  arbitrary attributes. Needs `Py_TPFLAGS_MANAGED_DICT` + full GC integration
  (traverse/clear/track), which is version-fragile across CPython 3.12–3.14;
  `dict=true` currently raises a clear "not yet supported" error. Subclasses can still
  add methods and class attributes.
- **`extends=`** — native inheritance *between* ParselTongue types or from a Python
  builtin (sharing fields/layout). Independent Julia structs can't share a C layout,
  so that case is unsupported.

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

From Python, you pass any callable — a `lambda`, a `def`, or a builtin — and it is
invoked back inside the Julia function:

```python
import mymod
mymod.apply(lambda x: x * 2.0, 3.0)        # 6.0
mymod.apply(abs, -5.0)                      # 5.0
mymod.combine(lambda a, b: a + b, 3, 4)     # 7
```

Internally, `f(a, b, …)` re-acquires the GIL and calls `PyObject_Call` through a
chain of `ccall`s emitted by a `@generated` method — one straight-line, trim-safe
body per concrete signature. Supported argument/return scalar types: `Int8`–`Int64`,
`UInt8`–`UInt64`, `Bool`, `Float32`, `Float64`. Array/string/object arguments and
returns to/from the callback are not yet supported.

## Distribution

Both ship a CLI: ParselTongue's `pt` is the analog of maturin. `pt build` /
`pt wheel` / `pt bench` compile, package, and benchmark without writing any Julia
(see [The pt CLI](/guide/cli)); the same operations are also available as the
`build_extension` / `build_wheel` functions.

```bash
pt wheel mymod.jl --runtime=system    # ParselTongue   (vs.  maturin build)
```

| | ParselTongue | PyO3 (via maturin) |
|---|---|---|
| Build CLI | `pt wheel mymod.jl` | `maturin build` |
| Emitted wheel size | **~1 MB** (`runtime=:shared`/`:system`) — comparable to PyO3 | ~1–5 MB |
| Runtime requirement | Julia runtime installed **once** (a `parseltongue-runtime` wheel, or system Julia ≥ 1.12), shared by every extension | none — Rust stdlib is linked statically |
| Self-contained option | `runtime=:bundled` (default): ~100 MB, vendors `libjulia`; `slim=true` → ~38 MB | the wheel is already self-contained |
| abi3 | `abi3=true` (CPython ≥ 3.11) | `abi3` feature (CPython ≥ 3.8) |
| manylinux | Auto-detected or `manylinux="2.17"` | Handled by `maturin` |
| macOS | `.dylib` + `@loader_path` rpaths | `.dylib` + `@rpath` |
| Windows | `.pyd`, `os.add_dll_directory` | Yes |

The emitted **wheel** is small — about 1 MB, like a PyO3 wheel — when you use
`runtime=:shared` or `runtime=:system`. The trade-off is that the Julia runtime
lives outside the wheel and is installed **once**: either as a separate
`parseltongue-runtime` wheel (`:shared`, vendors `libjulia` + its backends) or as a
system Julia ≥ 1.12 (`:system`). One runtime is then shared by all your extension
wheels.

`runtime=:bundled` (the default) instead vendors the whole Julia runtime into each
wheel (~100 MB) so it imports with nothing else installed. That size comes from the
Julia stdlib's `__init__`s, which fatally `dlopen` their native backends (OpenBLAS,
SuiteSparse, …) at startup even when unused; `slim=true` drops it to ~38 MB when
your code does not `using LinearAlgebra` or other stdlib JLLs. PyO3 has only the
one self-contained shape (its Rust stdlib is linked statically).

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
- You need **per-instance `__dict__`** on subclasses (`#[pyclass(dict)]`) so Python
  subclass instances can set arbitrary attributes; ParselTongue supports methods-only
  subclassing today (`subclass=true`), with instance `dict` planned.
- You need **native inheritance** (`#[pyclass(extends=...)]`): one native class
  sharing the fields/layout of another, or subclassing a Python builtin. ParselTongue
  supports Python subclassing of its types (`subclass=true`) but not field-sharing
  inheritance between independent Julia structs.
- You need an operator with **two different operand signatures on one method**
  (ParselTongue's `__mul__` is either `T×T` or `T×scalar`, not both at once).
- You need **free-threading** CPython.
- You need a fully self-contained wheel with **nothing installed once**: a PyO3
  wheel carries its whole runtime, whereas a ~1 MB ParselTongue wheel still needs a
  Julia runtime present (shared/system), and the self-contained `:bundled` wheel is
  ~100 MB.
- You need to call Python callbacks with **non-scalar argument types** (arrays,
  strings, objects); ParselTongue's `PyCallable{Args,Ret}` is limited to scalars.
- Your project already has Rust tooling in the CI pipeline.

## Both are good choices when

- You have a compute-intensive kernel (solver, simulation, parser) that you want
  to call from Python with minimal overhead.
- You want GIL-releasing parallelism across Python threads.
- You want stable-ABI (`abi3`) wheels that run on multiple CPython versions.
- You want proper Python exception propagation, not bare `abort()`.
