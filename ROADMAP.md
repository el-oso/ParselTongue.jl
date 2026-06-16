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

- Full `#[pyclass]`-style objects with inheritance / dunder protocols (basic
  real-Python-type handles shipped in Phase 4; inheritance and dunder injection deferred).
- `async`, free-threading, sub-interpreters.
- Windows ARM64 (x86-64 shipped v0.25.0 via MinGW-w64; ARM64 depends on Julia Windows arm64 support).
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

- [x] **D. `*args` — variadic positional arguments** *(argument ergonomics)* — shipped v0.18.0.
  - `PtVarArgs{T}` (`T <: _PtVarArgElt`, i.e. real numeric scalars) absorbs all remaining
    positional Python args beyond the fixed-arg count. Declared as the last positional arg:
    `@pyfunc f(x::Float64, rest::PtVarArgs{Float64})::Float64`. Julia sees a
    `PtVarArgs{T} <: AbstractVector{T}`, zero-copy from a malloc'd C array.
  - C shim: `METH_VARARGS`; checks `PyTuple_GET_SIZE(args) >= n_fixed`; extracts fixed
    args via `PyArg_Parse` on individual tuple items; loops the remainder with
    `PyTuple_GET_ITEM` + scalar `PyArg_Parse`; builds a `PtArray{T,1}` carrier; calls
    Julia; `free`s the C array after. Keyword-only args alongside varargs use
    `METH_VARARGS | METH_KEYWORDS` with an empty positional tuple for `ParseTupleAndKeywords`.
  - `_type_src` updated for `PtVarArgs{T}` (fully-qualified `ParselTongue.PtVarArgs{T}`).
  - `_register_export!` validates: last positional, no Mut, no default, single occurrence.
  - Skipped: `**kwargs` (requires opaque-PyObject infrastructure); positional-only `/` syntax.
  - Files: `boundary.jl`, `macros.jl`, `ccallable_gen.jl`, `cshim.jl`, `ParselTongue.jl`.
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
- [x] **7. macOS support** — shipped v0.20.0.
  `_link_extension` now branches on `Sys.isapple()`: macOS uses `-dynamiclib
  -undefined dynamic_lookup` (vs `-shared -fPIC`) and `-Wl,-force_load,img.a`
  (vs `--whole-archive`); both `-Wl,-rpath,...` and bare `-rpath` forms are
  stripped from julia-config output when `strip_abs_rpath=true`. `build_wheel`
  uses `@loader_path` rpaths on macOS (vs `$ORIGIN`); macOS dyld resolves
  `@loader_path` at load time relative to the `.so` file, so no env-var trick
  is needed for bundled wheels. `_vendor_libs`/`_vendor_libs_smart` detect
  `.dylib` via `_is_dynlib`; `_SKIP_LIB` regex matches both `.so` and `.dylib`
  variants. `_dynlib_needed` dispatches to `_otool_needed` (macOS, `otool -L`)
  or `_readelf_needed` (Linux, `readelf -d`) for slim-wheel BFS. Shared-runtime
  `__init__.py` on macOS uses `ctypes.CDLL(..., RTLD_GLOBAL)` to preload Julia
  dylibs (DYLD_LIBRARY_PATH is not re-read post-startup; Linux keeps
  LD_LIBRARY_PATH). Extension suffix (`EXT_SUFFIX` / `.abi3.so`) is handled
  by Python's sysconfig — no Julia change needed. `juliac --output-o` produces
  a `.a` archive on both platforms unchanged. Effort L.
- [x] **8. More boundary types** — `Bool`/`Int` arrays already work; add `Vector{String}`
  ↔ list[str], and `NamedTuple` ↔ dict return. `boundary.jl` + `cshim.jl`. Effort M each.

## Phase 3 — performance & polish

- [x] **E. `@boundary` extensibility protocol** *(ecosystem — gap vs PyO3 derive macros)* — shipped v0.19.0.
  - PyO3: `derive(FromPyObject)` / `derive(IntoPyObject)` let any crate add types.
    ParselTongue: `c_abi_type`/`from_c`/`to_c` exist but require manual impl with no
    convenience macro and no error guidance.
  - `@boundary T carrier=C begin from_c(c) = ...; to_c(x) = ... end` registers all
    three methods and validates against the `PyBoundary` contract immediately at macro
    expansion time via `_missing_boundary_methods`. Errors are raised at definition time
    (missing `from_c`, missing `to_c`, wrong `carrier=` syntax) rather than silently at
    juliac build time.
  - The macro emits `ParselTongue.c_abi_type`, `ParselTongue.from_c`, and
    `ParselTongue.to_c` method definitions (fully-qualified so they extend the right
    module from user code) then runs the validation check in the same `quote` block.
  - `@eval`-wrapped macro calls throw `LoadError` wrapping the `ErrorException`; test
    helpers unwrap via `err isa LoadError ? err.error : err`.
  - Files: `boundary.jl` (macro + export), `ParselTongue.jl` (`@boundary` in exports).
  - Done-when: a user package can define a custom boundary type without touching
    ParselTongue source. Effort M · Risk L.

- [x] **F. Python callables as arguments** *(gap vs PyO3 `Py<PyAny>` / `PyCallable`)* — shipped v0.21.0.
  - `PyCallable` boundary type: carrier `Ptr{Cvoid}` (raw PyObject* cast to void*).
    `c_abi_type` = `Ptr{Cvoid}`; `from_c` wraps pointer; `to_c` unwraps.
  - C shim: `"O"` format + `PyCallable_Check`; `Py_INCREF` before GIL release;
    `Py_DECREF` after call. The incref is inserted into acquired-cleanup chains via
    `_insert_cleanup_before_return` so earlier-arg failures also release correctly.
  - Julia-side functor `(f::PyCallable)(x::Float64)::Float64`: re-acquires GIL via
    `PyGILState_Ensure`, builds a one-element `PyTuple_New`, calls `PyObject_Call`,
    extracts `PyFloat_AsDouble`, releases GIL. All are direct `ccall` invocations —
    no Julia method dispatch — so trim-safe under `--trim=safe`. Note: the spike
    was skipped; the integration test build IS the trim-cleanliness proof.
  - `_zero_cval(Ptr{Cvoid})` = `"Ptr{Cvoid}(0)"` in ccallable_gen.
  - `ispycallable`, `_c_ctype`, `_carrier_tag`, `_arg_plan`, `_build_pyobject` in cshim.jl.
  - Integration fixture: `apply(f::PyCallable, x::Float64)::Float64 = f(x)` and
    `bisect(f, lo, hi)` (52-iteration bisection root finder).
  - Supports returning `PyCallable` (identity Py_INCREF path in `_build_pyobject`).
  - Limitation: only `Float64 → Float64` calling signature implemented; other
    scalar types would need additional functor overloads.

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
- [x] **10. CI + distribution polish** — shipped v0.15.0; updated v0.23.0.
  `.github/workflows/ci.yml`: single job, Julia 1.12 on ubuntu-latest; installs numpy,
  resolves TypeContracts via `[sources]` in `Project.toml` (URL entry replaces the old
  `Pkg.develop(url=...)` CI workaround — `Pkg.instantiate()` suffices). Runs unit tests
  first (fast feedback), then integration tests (juliac build + Python import; skips
  gracefully if tools absent). README updated with installation instructions and a current
  status section. **General registry**: blocked on TypeContracts being registered in
  General first; the rest of Project.toml (UUID, compat, extras) is already correct.
  Doctest of docs examples deferred (requires node/npm). Effort M.
- [x] **11. Startup latency** — shipped v0.14.0. `startup_benchmark(ext_path; call_expr, n, python)`
  runs `n` fresh-subprocess trials, times import and optional first call, returns a
  NamedTuple with `import_ms_median/min/max` and `call_ms_median/min/max`. Integration
  test now logs latency numbers after each build. Typical: ~1–3 s import (libjulia init),
  <1 ms first call (AOT-compiled). Effort S.

- [x] **G. `runtime=:system` wheel mode** *(size — ~1 MB, no bundled Julia)* — shipped v0.23.0.
  `build_wheel(file; runtime=:system)` produces a wheel with no vendored Julia runtime (~1 MB vs
  ~100 MB bundled). At import time, `__init__.py` locates Julia on the host via
  `_find_libdirs()` which tries in order: `JULIA_BINDIR` env var → `JULIA_PREFIX` env var →
  `julia` on PATH (subprocess `julia -e 'print(Sys.BINDIR)'`, handles juliaup launchers).
  After locating the lib dirs, the preload block is identical to `:shared`: Linux sets
  `LD_LIBRARY_PATH`; macOS loops `ctypes.CDLL(..., RTLD_GLOBAL)`. No `Requires-Dist` added
  (Julia is a system dependency, not a pip one). Wheel tag: `py3-none-<plat>`.
  The PATH fallback spawns a subprocess (~2 s) only once at first import; set `JULIA_BINDIR`
  in CI and containers to skip it. Files: `src/wheel.jl` (`_write_system_pkg_pyfiles` +
  `:system` branch); `src/cli.jl` (`--runtime=system` flag). Effort M.

- [x] **H. Pkg Apps CLI — `pt` via `julia app add`** *(distribution ergonomics)* — shipped v0.23.0.
  Julia 1.12 `Pkg.Apps` installs a shim at `~/.julia/bin/pt` that runs
  `julia -m ParselTongue [args]` → calls `ParselTongue.julia_main()`. Previously `julia_main`
  lived in `app/pt.jl` (Main namespace, for juliac). Moved all CLI logic into `src/cli.jl`
  (included by the module); `app/pt.jl` reduced to a 2-line juliac wrapper
  (`using ParselTongue: julia_main`). `Project.toml` declares `[apps.pt]`.
  Three invocation paths all work: (1) interpreted `julia --project=. app/pt.jl`, 
  (2) compiled binary (`app/build_app.jl` → juliac `--output-exe`), 
  (3) Pkg App shim (`julia app develop .` → `pt`). Files: `src/cli.jl` (new),
  `src/ParselTongue.jl`, `app/pt.jl`, `Project.toml`. Effort S.

## Phase 4 — optional capability track (stateful objects)

- [x] **12. Opaque-handle types → real Python classes (`@pyhandle`)** — `@pyhandle T`
  for isbitstype (immutable, all-isbits fields) structs stored on the C heap. Each handle
  type becomes a proper `PyTypeObject` (via `PyType_Spec`/`PyType_FromSpec`, stable-ABI
  compatible), so `isinstance(p, mod.Point2D)`, `repr(p)` → `<Point2D>`, and tab
  completion all work. Constructor `@pyfunc`s return handles; method `@pyfunc`s
  receive/return handles. Mutation is functional (return new handles). `free` is called
  automatically by the type's `tp_dealloc`. GC-root complexity avoided by restricting to
  isbitstype. `PtHandle{T}` parameterized carrier encodes the Julia type through the
  pipeline. No user-facing syntax change. Effort L · Risk M.

## Phase 5 — handle ergonomics + distribution

- [x] **J. User-defined dunders on handles (`@pymethod`)** — annotate a Julia function as a
  Python special method on a `@pyhandle` type, e.g.:
  ```julia
  @pymethod __repr__ point_repr(p::Point2D)::String = "<Point2D x=$(p.x) y=$(p.y)>"
  ```
  Implemented for `__repr__` and `__str__` (both `String`-returning, single `self` arg).
  `@pymethod` injects a `Py_tp_repr` / `Py_tp_str` slot into the per-type `_pt_slots_<T>[]`
  array before `PyType_FromSpec`, overriding the generated default. Each method becomes a
  `Base.@ccallable` wrapper (`pt_meth_<T>_<dunder>`) in the juliac entry, exactly like a
  `@pyfunc`. Trim-safe by construction. The declared return type is validated against the
  slot contract at registration time. `__eq__`/`__hash__` are future work (richcompare /
  hash slot wrappers). Files: `src/macros.jl` (`PtMethod` + `@pymethod`),
  `src/ccallable_gen.jl` (`emit_ccallable_method`), `src/cshim.jl` (slot injection),
  threaded through `build.jl`/`wheel.jl`. **Done v0.10.0.**

- [x] **K. Read-only field access via `__getattr__`** — for `@pyhandle T`, auto-generate a
  `Py_tp_getattro` slot that exposes every scalar `fieldname(T)` as a read-only Python
  attribute. No user annotation; fields and offsets are discovered at build time via
  `fieldoffset`/`fieldtype` (isbits layout == C layout). Reads the field bytes and converts
  with the existing scalar→PyObject builders. Uses `PyUnicode_CompareWithASCIIString`
  (stable-ABI safe); non-scalar fields and all dunders fall through to
  `PyObject_GenericGetAttr` so `repr`/`__class__` keep working.
  Files: `src/cshim.jl` (`_pt_getattr_<T>` + slot). **Done v0.10.0.**

- [x] **L. `PyCallable` with arbitrary signatures** — `PyCallable` is now
  `PyCallable{Args<:Tuple, Ret}`; the bare name aliases `Float64 → Float64` for compat.
  The call operator is a `@generated` method that emits one straight-line body per
  concrete signature: unrolled `_py_box` calls fill the argument tuple, `PyObject_Call`
  invokes the callback, and `_py_unbox` extracts the result via `Ret`. All ccalls + concrete
  `_py_box`/`_py_unbox` dispatch, so `--trim=safe` accepts it (validated by the integration
  build of a 2-arg fixture — no separate spike file needed). The C shim is unchanged: the
  carrier stays `Ptr{Cvoid}` for every signature (`ispycallable(C) = C === Ptr{Cvoid}`).
  Supported scalar arg/return types: `Int8`–`Int64`, `UInt8`–`UInt64`, `Bool`, `Float32`,
  `Float64`. Files: `src/boundary.jl` (parameterize + box/unbox + `@generated` operator),
  `src/ccallable_gen.jl` (`_type_src` PyCallable case). **Done v0.11.0.** Non-scalar
  callback args/returns remain future work.

- [x] **M. `pyproject.toml` generation** — `build_wheel(...; emit_pyproject=true)` writes a
  minimal PEP 621 `pyproject.toml` next to the `.whl`: `[build-system]` stub +
  `[project]` with name/version/description, `requires-python` (`>=3.11` for abi3, else the
  build interpreter version), a `parseltongue-runtime` dependency for `runtime=:shared`, and
  the `numpy` optional extra. Makes the output directory a publishable layout for
  `twine upload` / PyPI. Also exposed as `pt wheel … --emit-pyproject`.
  Files: `src/wheel.jl` (`_write_pyproject`), `src/cli.jl`. **Done v0.12.0.**

- [ ] **N. Multi-module wheels** — package several `@pymodule` source files into one wheel so
  they share a single Julia runtime image and can be imported together in one Python process.
  Avoids the one-extension-per-process limitation for same-runtime extensions. Approach:
  one `juliac --trim` invocation per module (or a single combined entry file); one
  `_<mod>.<ext>.so` per module; a top-level `__init__.py` that loads them all. Significant
  rpath / runtime-vendoring complexity — spike first.
  Files: `src/build.jl`, `src/wheel.jl`. Effort L · Risk M.

## Audit findings — 2026-06-16 (open)

Findings from a full source audit of `src/`. Grouped by severity. Fix bugs before
Phase 5 work; inconsistencies and improvements opportunistically.

### Bugs

- [x] **A1. `_bp_dict` key-string leak on error** (`cshim.jl:553`) — when
  `PyDict_SetItemString` fails mid-loop, the remaining key strings at indices
  `ii+1..len-1` that were already `strdup`'d are never freed. Fix: free remaining
  keys before breaking out of the loop, mirroring the `_ap_dict` cleanup pattern.

- [x] **A2. `_bp_opt` Cstring memory leak** (`cshim.jl:527`) — for
  `Union{String,Nothing}` returns, the inner `Cstring` value is passed to
  `PyUnicode_FromString` but never `free`'d. Every successful Optional String
  return leaks the Julia-malloc'd buffer. Fix: emit `free((void *)val.value);`
  after `PyUnicode_FromString`, matching what `_bp_str` does.

- [x] **A3. Keyword-only required args silently positional** (`cshim.jl:829`,
  `macros.jl:202`) — a `@pyfunc f(a::Int; kw::Float64)::Float64` where `kw` has
  no default passes `@pyfunc` validation but is emitted as `METH_VARARGS` (no
  kwargs dict), making it unreachable by keyword from Python. Fix: either reject
  keyword-only args without defaults in `_register_export!`, or detect
  `any(a.is_keyword for a in e.args)` in `_wrapper_fn` and force `METH_KEYWORDS`.

- [x] **A4. `PyFloat_AsDouble` error silently dropped in `PyCallable`**
  (`boundary.jl:612`) — if the Python callable returns a non-float object,
  `PyFloat_AsDouble` returns `-1.0` and sets a Python exception, but the Julia
  side never checks `PyErr_Occurred()`. The GIL is released and the exception
  state is lost. Fix: check `PyErr_Occurred() != C_NULL` after the call, clear
  the error, and `error(...)`.

- [x] **A5. `_pt_errmsg` not written on success path** (`ccallable_gen.jl:119`)
  — the generated `@ccallable` wrapper only stores into `_pt_errmsg` inside the
  `catch` block; on success the pointer is left as whatever the caller
  initialised. The C shim happens to zero-initialise it, but this is a latent
  contract violation. Fix: emit `unsafe_store!(_pt_errmsg, Ptr{UInt8}(0))` on
  the success path alongside `unsafe_store!(_pt_err, Int32(0))`.

### Inconsistencies

- [x] **A6. `_ap_stra` `memset` has no `ni>0` guard** (`cshim.jl:274`) — emits
  `memset(tmp.data, 0, (size_t)ni * sizeof(char *))` without a guard; `_ap_dict`
  uses `ni > 0 ? ... : 1`. Technically safe (memset of 0 bytes is a no-op) but
  looks like a bug at a glance. Align to `_ap_dict` style.

- [x] **A7. `has_kw` flag logic diverges between varargs and non-varargs**
  (`cshim.jl:1246`) — non-varargs uses `any(a.default !== nothing, e.args)`;
  varargs uses `any(a.is_keyword, e.args)`. Unify to
  `has_defaults || any(a.is_keyword, e.args)` in both paths.

- [x] **A8. Dict unsigned branch uses string prefix instead of type identity**
  (`cshim.jl:399`) — `startswith(cs.ctype, "u")` instead of explicit type
  identity checks as used in other branches. Fragile if a new type with a
  `ctype` beginning with `"u"` is added.

- [x] **A9. Dead `_MODULE_NAME[] = nothing` in `build.jl`** (`build.jl:102`) —
  `clear_exports!()` already sets `_MODULE_NAME[] = nothing`; the explicit
  assignment two lines later is dead code.

- [x] **A10. `_uses_bytes`/`_uses_strarr`/`_uses_handles` miss nested carriers**
  (`cshim.jl:984`) — these predicates check top-level return carriers and tuple
  fields but not carriers inside `PtOpt` or dict value types. Latent: currently
  Optional wrapping of bytes/strarr/handles is not generated, but the predicates
  should be exhaustive.

### Improvements

- [x] **A11. Naked `::Int` on `findfirst` in `_wrapper_fn_varargs`**
  (`cshim.jl:663`) — `findfirst(...)::Int` throws a `TypeError` instead of a
  clear message if it returns `nothing`. Replace with `something(findfirst(...))`.

- [x] **A12. `from_c(String, Cstring)` no null guard** (`boundary.jl:111`) —
  `unsafe_string(c)` with a null `Cstring` is undefined behaviour. Add
  `@assert c != C_NULL` (strips in AOT; avoids dynamic dispatch from `error()`).

- [x] **A13. `@pyhandle to_c` malloc return unchecked** (`boundary.jl:171`) —
  `Ptr{T}(Libc.malloc(sizeof(T)))` not checked for null before `unsafe_store!`;
  OOM segfaults instead of erroring. Add `@assert p != C_NULL`.

- [x] **A14. `to_c(String)` malloc return unchecked** (`boundary.jl:115`) — same
  pattern: `Ptr{UInt8}(Libc.malloc(n + 1))` before `unsafe_copyto!` without a
  null check. Add `@assert p != C_NULL`.

- [x] **A15. `PyLong_FromSsize_t` return unchecked in `_pt_wrap_ndarray`**
  (`cshim.jl:1142`) — on OOM, returns NULL which is then passed to
  `PyTuple_SetItem` (which steals the ref), leaving a NULL element in the shape
  tuple. Check the return value and propagate NULL on failure.

- [x] **A16. Missing ownership comment in `_pt_wrap_ndarray`** (`cshim.jl:1136`)
  — the ordering of `Py_DECREF(flat)` before checking `arr` is correct but
  subtle (numpy never took ownership of `buf` if `frombuffer` failed). Add a
  comment explaining the invariant.

- [x] **A17. `doc` string unescaped in generated `PyModuleDef`** (`cshim.jl:1260`)
  — `doc` is interpolated verbatim into a C string literal. Currently always a
  static string, but if ever exposed via `build_extension(...; doc=)` a user
  value containing `"` or `\` would produce malformed C. C-escape before
  interpolation.

- [x] **A18. Method docstring escape relies on implicit invariant** (`cshim.jl:1250`)
  — `export_name` is safe in a C literal only because `_is_py_ident` validates
  it. Add a comment cross-referencing the validator so the dependency is explicit.

- [x] **A19. `_opt_inner` assumes binary Union** (`boundary.jl:463`) — returns
  wrong type for `Union{A, B, Nothing}` (three-way). Add an `@assert` that
  exactly one of `T.a`, `T.b` is `Nothing`.

- [x] **A20. `PtVarArgs` not blocked as return type** (`macros.jl:297`) —
  `assert_ret_boundary` passes for `PtVarArgs{T}` since it has `to_c` defined,
  but returning a varargs container is semantically nonsensical. Reject it in
  `assert_ret_boundary` or `_register_export!`.

- [x] **A21. Extra positional CLI args silently ignored** (`cli.jl:84`) — `pt
  build file1.jl file2.jl` silently ignores `file2.jl`. Emit a warning or error.

- [x] **A22. Runtime version pin fragile for pre-release Julia** (`wheel.jl:198`)
  — `~= X.Y.0` version pin derived from `VERSION` string; a nightly
  `1.13.0-DEV` would produce `~= 1.13.0` which pip won't match against a
  `parseltongue-runtime 1.13.0.DEV` package. Document the limitation.

## Known correctness issues (audit findings — fix opportunistically)

- ~~**`_link_extension` redundant Python query**~~ — fixed v0.8.0.
- ~~**`assert_boundary` stale error message**~~ — fixed v0.8.0.
- ~~**`_wheel_meta` hardcodes version**~~ — fixed v0.8.0 (now uses `pkgversion`).
- ~~**`PyDict_SetItemString` return unchecked**~~ — fixed v0.17.0. Each call in
  the NamedTuple → dict return path now checks the return value and propagates
  OOM errors with correct refcount cleanup.
- ~~**Multiple array args: buffer leak on late arg failure**~~ — fixed v0.17.0.
  `_insert_cleanup_before_return` rewrites each arg's setup error paths to include
  releases of all previously acquired buffers/arrays. Handles bare `if (cond)
  return NULL;` (wrapped with braces) and embedded `return NULL;` inside blocks.
- ~~**`build_wheel` double-includes user file**~~ — fixed v0.17.0. `build_wheel`
  now passes `_preloaded=(exports, errors)` to `build_extension`, which skips the
  second include. The user file is loaded exactly once per `build_wheel` call.

- [x] **I. Windows support (MinGW-w64)** *(platform breadth)* — shipped v0.25.0. Verified via CI on `windows-latest`.
  All Windows platform branches implemented and passing unit + integration tests on GitHub Actions.
  Files: `src/build.jl` (`_find_cc` Windows search, `_py_lib_flags`, `_link_extension` Windows branch,
  `_abi3_ext_suffix` `.pyd` fallback); `src/wheel.jl` (`_is_dynlib` `.dll`, `_SKIP_LIB` `.dll`,
  `_vendor_libs_win`, `_objdump_needed`, `_dynlib_needed` Windows dispatch, `build_wheel` Windows
  vendoring from `bin/`, `_write_pkg_pyfiles`/`_write_shared_pkg_pyfiles`/`_write_system_pkg_pyfiles`
  Windows preload via `os.add_dll_directory`, `build_runtime_wheel` Windows vendoring,
  `_current_os_kernel` helper). MSVC not supported — use MinGW-w64 gcc (pre-installed at
  `C:\msys64\mingw64\bin` on GitHub runners; CI adds it to PATH automatically).

## Cross-cutting conventions

- Spike risky/unknown items in `spike/` before wiring them in (esp. #1 exceptions, #9).
- Every shipped item adds: an example under `examples/`, a unit + integration test,
  and a docs section. Keep the boundary contract and trim-safety invariant.
- Track progress by ticking the checkboxes above across sessions.
