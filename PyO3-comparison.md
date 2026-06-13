# ParselTongue.jl vs. Rust PyO3 — a comparison

A candid comparison of **ParselTongue** (Julia → native Python extensions via
`juliac --trim`) and **PyO3 + maturin** (Rust → native Python extensions), the
de-facto standard it's measured against.

> Scope note: ParselTongue details are exact (from its implementation). PyO3
> details reflect general knowledge of a fast-moving project — verify version-
> specific claims (abi3, free-threading, etc.) against current PyO3 docs.

---

## TL;DR

PyO3 is a **mature, general-purpose** way to write *any* Python extension in
Rust: classes, exceptions, callbacks, async, tiny wheels, many Python versions
from one build. It's production-proven (pydantic-core, polars, cryptography,
tokenizers, …).

ParselTongue is a **young, focused** way to expose *plain Julia numerical
functions* to Python with very low author friction and zero-copy NumPy — at the
cost of a large bundled runtime, one-extension-per-process, and a restricted
(but growing) type surface. Its bet: if you already think in Julia and your code
is type-stable, shipping a fast extension is dramatically less ceremony than Rust.

**Choose PyO3** for general-purpose, polished, widely-distributed extensions.
**Choose ParselTongue** when the implementation is naturally Julia (numerics,
scientific computing) and you want "write a function, get a wheel."

---

## At a glance

| | **ParselTongue** | **PyO3 + maturin** |
|---|---|---|
| Source language | Julia | Rust |
| Maturity | v0.1, experimental (rides experimental `juliac --trim`) | Mature, production-grade |
| Author friction | Very low: plain Julia + one macro | Moderate: Rust + macros, ownership/lifetimes, GIL tokens |
| Build command | one (`build_wheel`) | one (`maturin build`) |
| User experience | `pip install` → `import` | `pip install` → `import` |
| Wheel size | ~100 MB (bundles Julia runtime) | a few MB (no runtime) |
| Startup | runtime init on first call (ms) | instant |
| Python versions per wheel | one (Python-specific) | one, **or many via abi3/stable ABI** |
| Multiple extensions / process | ❌ one Julia runtime per process | ✅ fine |
| Custom classes / exceptions | ❌ (functions only) | ✅ `#[pyclass]`, custom exceptions |
| Callbacks into Python | ❌ | ✅ |
| Async | ❌ | ✅ (pyo3-async) |
| NumPy | ✅ transparent, zero-copy, runtime-only dep | ✅ via `rust-numpy` crate |
| Free-threaded / sub-interpreters | ❌ | partial/evolving |
| Ecosystem to lean on | Julia packages (with trim constraints) | crates.io |

---

## Developer experience

**ParselTongue** — annotate plain Julia; types are the boundary contract:

```julia
using ParselTongue
@pymodule fast begin
    @pyfunc rowsums(A::AbstractMatrix{Float64})::Vector{Float64} = vec(sum(A, dims=2))
    @pyfunc scale!(x::Mut{Vector{Float64}}, k::Float64)::Nothing = (x .*= k; nothing)
end
```
```julia
build_wheel("fast.jl")          # → dist/fast-…whl
```

**PyO3** — Rust with attribute macros, explicit conversions and (where relevant)
GIL/lifetime handling:

```rust
use pyo3::prelude::*;
use numpy::{PyReadonlyArray2, PyArray1, IntoPyArray};

#[pyfunction]
fn rowsums<'py>(py: Python<'py>, a: PyReadonlyArray2<f64>) -> Bound<'py, PyArray1<f64>> {
    let a = a.as_array();
    let v: Vec<f64> = a.rows().into_iter().map(|r| r.sum()).collect();
    v.into_pyarray_bound(py)
}

#[pymodule]
fn fast(m: &Bound<'_, PyModule>) -> PyResult<()> {
    m.add_function(wrap_pyfunction!(rowsums, m)?)?;
    Ok(())
}
```
```bash
maturin build --release
```

The contrast: ParselTongue hides the C-ABI boundary, GIL, and refcounting behind
codegen — you never see a `PyObject`. PyO3 surfaces them, which is what makes it
*general* (and why it asks more of you). For a numeric kernel, ParselTongue is
markedly less code; for anything stateful or object-shaped, PyO3 is the only one
that can express it at all.

---

## Type system & data exchange

**ParselTongue** marshals a fixed (extensible) set of *boundary types*:

- scalars (`Int*`/`UInt*`/`Bool`/`Float32/64`), **complex** (`ComplexF32/64`)
- `String`
- N-D numeric/complex arrays, zero-copy, with a **dual policy chosen by the
  argument type**: `::AbstractArray` → logical NumPy-shaped view;
  `::Array` → dense BLAS-friendly (transposed for C-order input)
- in-place `Mut{T}` (writes back to the caller's NumPy buffer)
- `Nothing` (void) and `Tuple{…}` returns

A non-boundary type is rejected **at build time** with a clear message (a
TypeContracts contract), not a cryptic compiler error. There is no path for
arbitrary Python objects, dicts→structs, custom classes, or returning Python
callables.

**PyO3** converts essentially the whole Python object model via
`FromPyObject`/`IntoPy` (and `#[derive(FromPyObject)]`): ints, floats, str,
bytes, list/tuple/dict/set, datetime, your own `#[pyclass]` types, `Option`,
`Result`→exception, etc. NumPy via `rust-numpy` gives zero-copy `ndarray` views.
It can model state (`#[pyclass]`), raise typed exceptions, and accept/return
callables.

Net: PyO3's type surface is effectively "all of Python"; ParselTongue's is "the
numeric boundary, done ergonomically," and it owns the NumPy row/column-major
question explicitly rather than leaving it to you.

---

## Build, packaging & distribution

**Wheel size & runtime.** This is the starkest difference. Rust has no runtime,
so a PyO3 wheel is just the compiled `.so` (a few MB). A ParselTongue wheel
**bundles libjulia + its stdlib backends (~100 MB)** because the trimmed runtime
dlopens them at init even when unused. A planned optimization (suppressing unused
stdlib inits) and an optional shared-runtime wheel could shrink this, but today
it's heavy.

**Python versions.** PyO3 supports the **stable ABI (abi3)**: one wheel works
across many CPython versions. ParselTongue's extension is built against a specific
CPython and is Python-version-specific (the bundled Julia runtime, however, is
Python-agnostic). PyO3 also has mature **manylinux** support via maturin;
ParselTongue currently emits a platform-tagged wheel without manylinux auditing.

**Multiple extensions.** Any number of PyO3 extensions coexist in one process.
**ParselTongue is one-extension-per-process** — each wheel embeds its own
libjulia, and two Julia runtimes can't coexist. Mitigation: put everything in one
module and use `@pymodule pkg.sub` submodules over a single image.

**Toolchain.** Both are "one command." maturin is a mature, widely-used tool with
publishing, develop mode, and CI integrations. ParselTongue's `build_wheel`/
`build_extension` are young and Linux-focused today (needs a C compiler + Python
headers + a Julia that ships `juliac`).

---

## Runtime & performance

- **Compute.** Both produce native machine code. AOT-trimmed Julia and optimized
  Rust are in the same ballpark for tight numeric loops; real differences come
  from the *libraries* (Julia's BLAS/LinearAlgebra vs. Rust crates) and how much
  copying each binding does.
- **Marshalling overhead.** Both aim for zero-copy arrays. ParselTongue's scalar
  path compiles to a direct call; array *returns* currently copy into a Python
  `bytearray` then wrap with `numpy.frombuffer` (one extra copy) — optimizable.
  PyO3 array returns can hand ownership to NumPy without that copy.
- **Startup.** PyO3: instant. ParselTongue: the trimmed runtime initializes on the
  first `@ccallable` call (sub-second), then steady-state.
- **GC & memory.** Julia is garbage-collected; ParselTongue's boundary uses an
  explicit "Julia mallocs / C frees" rule for returns to avoid GC-timing hazards.
  Rust is ownership-based with no GC.
- **Concurrency.** PyO3 gives explicit control over the GIL and is moving toward
  free-threading. ParselTongue does not expose threading across the boundary and
  inherits the one-runtime-per-process constraint.

---

## Capability matrix

| Capability | ParselTongue | PyO3 |
|---|---|---|
| Free functions | ✅ | ✅ |
| Custom classes / methods | ❌ | ✅ `#[pyclass]` |
| Raise typed Python exceptions | ❌ (errors abort/propagate generically) | ✅ |
| Accept/return Python callables | ❌ | ✅ |
| Keyword/default/variadic args | ❌ (positional only) | ✅ |
| Arbitrary Python objects | ❌ | ✅ |
| Zero-copy NumPy in | ✅ | ✅ |
| NumPy ndarray out | ✅ (runtime-resolved, one copy) | ✅ |
| N-D arrays | ✅ (dual order policy) | ✅ |
| Complex numbers | ✅ | ✅ |
| In-place mutation | ✅ `Mut{}` | ✅ |
| Async | ❌ | ✅ |
| Build-time deps | none beyond cc + Python headers | Rust toolchain |
| numpy at build time | not required | optional (rust-numpy) |

---

## Where ParselTongue is genuinely nicer

- **Lowest author friction for numeric code** if you already write Julia: no
  Rust, no lifetimes, no `PyObject`, no manual refcounting — the macro + types
  are the whole interface.
- **Leverages Julia's numerical ecosystem & language** (multiple dispatch,
  broadcasting, LinearAlgebra) directly in the implementation.
- **NumPy is transparent and never a build dependency** — resolved at runtime;
  the same wheel degrades to `memoryview` where NumPy is absent.
- **Build-time type checking** with human-readable errors instead of trait/borrow
  diagnostics.
- **Explicit, principled answer to the NumPy↔Julia memory-order problem** (the
  dual policy), rather than silent transposes.

## Where PyO3 is clearly ahead

- **Maturity, stability, and adoption** — battle-tested in major packages.
- **Full expressiveness** — classes, exceptions, callbacks, async, the whole
  Python object model.
- **Distribution** — tiny wheels, abi3 (one wheel for many Pythons), manylinux,
  polished publishing via maturin.
- **No runtime singleton** — compose many extensions freely; play nicely with the
  rest of a process.
- **Toolchain & docs** — large community, extensive documentation, CI recipes.

---

## When to choose which

**Reach for ParselTongue when:**
- the kernel is naturally Julia (scientific computing, numerics, array math);
- you want the absolute least ceremony to expose functions to Python;
- the API is functions over numbers/strings/arrays (not objects);
- a large wheel and one-extension-per-process are acceptable;
- you're comfortable on the leading edge of an experimental toolchain.

**Reach for PyO3 when:**
- you need classes, exceptions, callbacks, async, or arbitrary Python types;
- you must ship small wheels and/or support many Python versions from one build;
- multiple native extensions share a process;
- production maturity and broad platform support matter;
- Rust is an acceptable (or desired) implementation language.

---

## Honest verdict

PyO3 is the right default for *general* native extensions and for anything that
ships widely — it's mature, expressive, and produces lean, broadly-compatible
wheels. ParselTongue isn't trying to be general; it's trying to make *Julia
numerical code* reachable from Python with minimal friction and good NumPy
ergonomics, and within that niche it already delivers a genuinely lighter authoring
experience. Its current costs — ~100 MB wheels, one runtime per process, a limited
type surface, and dependence on the still-experimental `juliac --trim` — are real
and keep it a specialist tool today, not a PyO3 replacement. The interesting
question is how far the niche extends as trim matures and the runtime footprint
shrinks.
