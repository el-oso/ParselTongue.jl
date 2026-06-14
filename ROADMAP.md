# ParselTongue → PyO3 gap-closing roadmap

A living, multi-session checklist. Tick items as they land; each is sized to be
picked up independently. See `PyO3-comparison.md` for the gap analysis behind it.

## Context

The PyO3 comparison surfaced concrete gaps. Goal: **get closer, not parity** —
keep ParselTongue a focused, low-friction Julia→Python numeric bridge while
removing its most-felt rough edges. Approach: **balanced** — interleave
robustness, distribution, and performance so each phase improves a different
axis. Trim-safety (`--trim=safe`) and the boundary-type model stay invariant
throughout; risky items get a spike first.

Code map: `src/boundary.jl` (carriers + `c_abi_type`/`from_c`/`to_c`),
`src/macros.jl` (`@pyfunc`/`@pymodule`, `PtExport`), `src/ccallable_gen.jl`
(`@ccallable` wrappers), `src/cshim.jl` (C PyInit shim), `src/build.jl`,
`src/wheel.jl`.

## Non-goals (explicit — keep the niche)

- Full `#[pyclass]`-style objects with inheritance / dunder protocols (a *scoped*
  opaque-handle track is optional — Phase 4).
- Callbacks into Python / passing Python callables into Julia.
- `async`, free-threading, sub-interpreters.
- Windows (initially — macOS first).
- Removing one-extension-per-process (inherent to the trim-image model; mitigated
  by `@pymodule pkg.sub` submodules, already shipped).

## Per-item template

Each item: **what gap / approach / files / effort (S/M/L) / risk / done-when**.
"Done-when" = an example builds, imports in a sanitized (no-Julia) subprocess, and
asserts; plus a unit/integration test and a docs note. Run `julia --project=. test/runtests.jl`.

---

## Phase 1 — the most-felt gaps (one robustness · one distribution · one perf)

- [x] **1. Julia error → Python exception** *(robustness; the top correctness gap)*
  - Gap: today a runtime error in a `@pyfunc` body crosses the `@ccallable`
    boundary unhandled → likely aborts the interpreter. PyO3 raises a Python
    exception. Only input-validation errors are handled now.
  - Approach: generate the wrapper body inside a `try`/`catch`; on catch, signal an
    error to the shim, which calls `PyErr_SetString` and returns `NULL`. Because
    value-returning `@ccallable`s can't also return an error, use a **C error
    out-parameter** convention: every `pt_<fn>` gains a trailing `int *err, char
    **errmsg` (or a per-call thread-local last-error queried by the shim). The shim
    checks it after the call and raises.
  - **Spike first (risk):** confirm `juliac --trim=safe` accepts `try`/`catch` and
    `sprint(showerror, e)` in an exported path. If trim rejects exceptions, fall back
    to: a `Base.@ccallable` that returns a status code + writes a malloc'd message,
    catching only via a trim-safe mechanism. `spike/` is the place to verify.
  - Files: `ccallable_gen.jl` (wrap call, error signaling), `cshim.jl` (`_wrapper_fn`
    checks err + raises; `_extern_decl` adds the err out-params), maybe `build.jl`.
  - Effort M · Risk M (trim try/catch support unknown) · Done-when: a `@pyfunc` that
    `error("boom")` raises a Python `RuntimeError` instead of crashing.

- [x] **2. abi3 (stable-ABI) shim — one wheel across CPython versions** *(distribution)*
  - Gap: each extension wheel is Python-version-specific; PyO3 ships one abi3 wheel
    for many. The shim's C-API surface is **almost entirely in the limited API**;
    the only floor-setter is the buffer protocol (`PyObject_GetBuffer` etc.), which
    entered the limited API in **Python 3.11** → abi3 floor 3.11 (fine today).
  - Approach: emit `#define Py_LIMITED_API 0x030B0000` in the shim, use the abi3
    extension suffix (`.abi3.so`) and wheel tag (`cp311-abi3-<plat>`). Gate behind
    `build_extension(...; abi3=true)` / `build_wheel(...; abi3=true)`.
  - `_PtBuf` type registration refactored to `PyType_Spec`/`PyType_Slot`/`PyType_FromSpec`
    (works in both full and limited API). Macro-only C API (`PyList_GET_SIZE`, etc.)
    replaced with function equivalents everywhere. Complex inputs use
    `PyComplex_RealAsDouble`/`ImagAsDouble` under abi3 (`Py_complex` not in 3.11 stable ABI).
  - Files: `cshim.jl`, `build.jl` (abi3 ext suffix via `importlib`), `wheel.jl`
    (`_wheel_tag_abi3` → `cp311-abi3-<plat>`).
  - Effort M · Risk L–M · Done-when: one wheel imports under two different CPython
    3.x minors.

- [x] **3. Release the GIL during compute + zero-copy array returns** *(performance)*
  - Gap: the shim holds the GIL for the whole call (blocks other Python threads),
    and array **returns** do one extra copy (malloc → `bytearray` → `frombuffer`).
  - GIL: wrap only the `pt_<fn>(...)` call in `Py_BEGIN_ALLOW_THREADS` /
    `Py_END_ALLOW_THREADS` (safe — no Python objects touched while released; input
    `Py_buffer`s stay pinned). Big win for long kernels. *(S)*
  - Zero-copy returns: hand the malloc'd result buffer to NumPy with ownership via a
    `PyCapsule` destructor that `free`s it, exposed through a tiny buffer-object +
    `numpy.frombuffer` (all limited-API). Removes the copy. *(M–L, fiddly)*
  - Files: `cshim.jl` (`_wrapper_fn` GIL macros; `_build_pyobject`/`_WRAP_ARRAY_HELPER`
    capsule path).
  - Effort S+M · Risk M · Done-when: a long kernel runs concurrently with another
    Python thread; array return shares memory (no copy) verified.

---

## Phase 2 — broaden distribution + ergonomics

- [x] **A. Custom exception types** *(ergonomics — gap vs PyO3)* — shipped v0.11.0.
  `@pyerror DomainError` / `@pyerror MyError <: ValueError` registers a Julia exception
  type as a named Python exception. `clear_exports!` clears both `_EXPORTS` and `_ERRORS`.
  ABI: `_pt_err` encodes the exception index (1=RuntimeError, 2+=registered[i-2]) — no
  4th out-param needed. Catch block emits trim-safe isa chain in registration order;
  ErrorException message extraction is independent (fires for any `<: ErrorException`).
  C shim emits `static PyObject *pt_err_<Name>` globals + `PyErr_NewException` +
  `PyModule_AddObject` in `PyInit_<mod>`; wrapper dispatch uses if/else code chain.
  `build.jl` copies `_ERRORS` alongside `_EXPORTS` and passes both to codegen.
  Done-when: Python `except mod.DomainError` catches a specific Julia exception type.
  Effort M · Risk L.

- [x] **B. `Dict{String,V}` + `Vector{UInt8}` boundary types** *(type breadth)* — shipped v0.12.0.
  Carrier `PtDict{V}` (`{char **keys; V *vals; int64_t len;}`) for `Dict{String,V}` where
  V ∈ scalar types. `from_c` iterates parallel arrays and calls `Libc.free`; `to_c` mallocs
  and strdup-s keys. All 11 scalar types registered via `@eval` loop. `Vector{UInt8}` returns
  use the existing `PtArray{UInt8,1}` carrier with a special `_pt_make_bytes` path in
  `_build_pyobject` → `PyBytes_FromStringAndSize` (instead of numpy). `_uses_bytes` predicate
  controls when the bytes helper is emitted. Dict arg plan: `PyDict_Check`, `PyDict_Next`,
  `PyUnicode_AsUTF8AndSize` for keys, `PyFloat_AsDouble`/`PyLong_AsLongLong`/`PyObject_IsTrue`
  for typed value extraction with inline error+cleanup. Fixed `_missing_boundary_methods` to
  use try/call (not `hasmethod`) since the Optional catch-all made hasmethod unreliable.
  Effort M · Risk L.

- [x] **C. `Union{T,Nothing}` nullable arguments** *(type breadth — gap vs PyO3 `Option<T>`)*
  Shipped v0.10.0. Carrier `PtOpt{C}` struct `{ int32_t has_value; <c_abi_type(T)> value; }`;
  isbitstype for scalar/Cstring inners. `c_abi_type` catch-all detects `Union{T,Nothing}`;
  `from_c` → `nothing` when `has_value=0`; `_to_c_opt` for returns takes the carrier type
  explicitly so the `nothing` branch can zero-fill. Shim parses with `"O"` format, checks
  `Py_None` pointer equality, fills struct inline. v1 supports scalar and String inner types.
  Fix: `_missing_boundary_methods` switched from `hasmethod` to try/call to survive the
  catch-all method. Effort S · Risk L.

- [ ] **D. `*args` / `**kwargs` / positional-only** *(argument ergonomics)*
  - Positional-only: `@pyfunc f(a, b, /, c)` — the `/` already separates in Julia;
    shim only needs to set the sentinel in `ml_doc` and stop keyword parsing before `/`.
  - `*args`: Julia splat `args...::NTuple{N,T}` → Python `*args`; shim extracts the
    remainder of the positional tuple as a `PyTuple` and converts.
  - `**kwargs`: trailing `kwargs::Dict{String,Any}` → Python `**kwargs`; shim passes
    the full `kwds` dict into Julia.
  - Files: `macros.jl` (detect splat + pos-only), `cshim.jl` (emission logic).
  - Effort M · Risk L.

- [x] **4. Shared-runtime wheel** *(size)* — tiny extension wheels that depend on a
  generated `parseltongue-runtime` wheel (vendors libjulia once, Python-agnostic tag).
  `build_runtime_wheel()` + `build_wheel(...; runtime=:shared)` — shipped in v0.8.0.
  The package `__init__.py` sets `LD_LIBRARY_PATH` to the runtime package's `julia/lib`
  dirs before importing the extension. glibc re-reads `LD_LIBRARY_PATH` at each `dlopen`
  call, so setting it in Python just before `from ._mod import ...` works correctly.
  The extension .so is linked with `runtime_rpaths=[]` and `strip_abs_rpath=true` so it
  carries no absolute rpaths; resolution happens entirely via LD_LIBRARY_PATH at import.
  The runtime wheel tag is `py3-none-<plat>` (any Python 3, platform-specific).
  Version defaults to the Julia version string (`VERSION`). Extension wheel METADATA adds
  `Requires-Dist: parseltongue-runtime ~= <major>.<minor>.0`.
- [x] **5. Keyword / default arguments** — `@pyfunc f(a; b=1.0)`; shim uses
  `PyArg_ParseTupleAndKeywords`. `macros.jl` records defaults; `cshim.jl` emits the
  keyword list. Effort M.
- [x] **6. manylinux tagging** — shipped v0.13.0. `_manylinux_plat(python; manylinux=true)`
  detects glibc via `platform.libc_ver()` and substitutes `linux_ARCH` →
  `manylinux_MAJOR_MINOR_ARCH`. `_wheel_tag` / `_wheel_tag_abi3` / `build_wheel` all
  accept `manylinux=true` (auto), `manylinux="2.17"` (pinned floor — recommended for
  Julia 1.12+ which targets glibc ≥ 2.17), or `manylinux=false` (raw tag). Skips
  auditwheel entirely (it would double-vendor libjulia); just sets the tag. Effort M · Risk M.
- [ ] **7. macOS support** — `.dylib`, `@loader_path` rpaths, ext suffix; juliac on
  macOS. `build.jl`/`wheel.jl` platform branches. Effort L.
- [x] **8. More boundary types** — `Bool`/`Int` arrays already work; add `Vector{String}`
  ↔ list[str], and `NamedTuple` ↔ dict return. `boundary.jl` + `cshim.jl`. Effort M each.

## Phase 3 — performance & polish

- [ ] **E. `@boundary` extensibility protocol** *(ecosystem — gap vs PyO3 derive macros)*
  - PyO3: `derive(FromPyObject)` / `derive(IntoPyObject)` let any crate add types.
    ParselTongue: `c_abi_type`/`from_c`/`to_c` exist but require manual impl with no
    convenience macro and no error guidance.
  - Add `@boundary T carrier=C from_c=(carrier -> T) to_c=(T -> carrier)` macro that
    auto-registers all three methods and validates against the `PyBoundary` contract at
    definition time (not silently at build time).
  - Files: `macros.jl` (new macro), `boundary.jl` (expose hook).
  - Done-when: a user package can define Arrow.Table → list-of-dicts without touching
    ParselTongue source. Effort M · Risk L.

- [ ] **F. Python callables as arguments** *(gap vs PyO3 `Py<PyAny>` / `PyCallable`)*
  - Spike first in `spike/` — verify `ccall(:PyObject_Call, ...)` from inside a
    `--trim=safe` binary compiles without dynamic dispatch rejection.
  - Boundary type `PyCallable`: carrier `Ptr{Cvoid}` (PyObject*); `from_c` just stores
    the pointer; `to_c` returns it. Julia side wraps in a closure that calls
    `ccall(:PyObject_Call, Ptr{Cvoid}, (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}), fn, args, C_NULL)`
    and re-acquires the GIL before calling.
  - Done-when: `@pyfunc minimize(f::PyCallable, x0::Float64)::Float64` accepts a
    Python lambda and calls it from Julia. Effort L · Risk M (spike first).

- [x] **9. Shrink the bundle** *(size)* — `readelf -d` analysis shows that the
  extension .so only needs 6 Julia libs via DT_NEEDED (`libjulia-internal`, `libstdc++`,
  `libgcc_s`, `libunwind`, `libatomic`, `libz` ≈ 38 MB) — the other ~70 MB
  (OpenBLAS/SuiteSparse/GMP/curl/ssl/etc.) is over-vendored. Shipped in v0.9.0.
  `build_wheel(...; slim=true)` uses `readelf -d` BFS (`_transitive_needed` +
  `_vendor_libs_smart`) to compute the transitive DT_NEEDED closure of the extension
  .so and only vendors libs in that closure. `bundle_size_report(whl_path)` is a
  utility for auditing wheel contents.
  **Warning**: `slim=true` breaks extensions that `using LinearAlgebra`/`SuiteSparse`
  — those JLL `__init__`s dlopen their libs at startup via `dlopen` (not DT_NEEDED),
  so those libs are absent from the transitive closure and will cause `ImportError`.
- [ ] **10. CI + distribution polish** — GitHub Actions wheel matrix (Python × plat),
  doctest the docs examples, prep for Julia General registry. Effort M.
- [x] **11. Startup latency** — shipped v0.14.0. `startup_benchmark(ext_path; call_expr, n, python)`
  runs `n` fresh-subprocess trials, times import and optional first call, returns a
  NamedTuple with `import_ms_median/min/max` and `call_ms_median/min/max`. Integration
  test now logs latency numbers after each build. Typical: ~1–3 s import (libjulia init),
  <1 ms first call (AOT-compiled). Effort S.

## Phase 4 — optional capability track (stateful objects)

- [x] **12. Opaque-handle types (~scoped `#[pyclass]`)** — `@pyhandle T` for isbitstype
  (immutable, all-isbits fields) structs stored on the C heap. A constructor `@pyfunc`
  returns a `PyCapsule`; method `@pyfunc`s receive/return handles. Mutation is
  functional (return new handles). `free` is called automatically by the capsule
  destructor. GC-root complexity avoided by restricting to isbitstype. `build.jl` uses
  `Base.invokelatest` so `c_abi_type` dispatch sees `@pyhandle`-registered methods.
  `_type_src` strips sandbox module qualifiers for user-defined types. Effort L · Risk M.

## Known correctness issues (audit findings — fix opportunistically)

- ~~**`_link_extension` redundant Python query**~~ — fixed v0.8.0.
- ~~**`assert_boundary` stale error message**~~ — fixed v0.8.0.
- ~~**`_wheel_meta` hardcodes version**~~ — fixed v0.8.0 (now uses `pkgversion`).
- **`PyDict_SetItemString` return unchecked** (`cshim.jl:_ret_plan`): for NamedTuple
  returns, `PyDict_SetItemString` can return -1 on OOM. Should check and propagate.
- **Multiple array args: buffer leak on late arg failure** (`cshim.jl:_wrapper_fn`):
  if arg 2's `PyObject_GetBuffer` fails after arg 1's succeeded, arg 1's
  `PyBuffer_Release` is in `cleanup` which never runs. Low severity (Python GC
  eventually handles it) but incorrect. Fix: add cleanup to setup's early-return paths.
- **`build_wheel` double-includes user file**: once for mod name, once in
  `build_extension`. Refactor to accept an already-resolved mod name.

## Cross-cutting conventions

- Spike risky/unknown items in `spike/` before wiring them in (esp. #1 exceptions, #9).
- Every shipped item adds: an example under `examples/`, a unit + integration test,
  and a docs section. Keep the boundary contract and trim-safety invariant.
- Track progress by ticking the checkboxes above across sessions.
