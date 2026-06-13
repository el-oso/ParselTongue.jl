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

- [ ] **2. abi3 (stable-ABI) shim — one wheel across CPython versions** *(distribution)*
  - Gap: each extension wheel is Python-version-specific; PyO3 ships one abi3 wheel
    for many. The shim's C-API surface is **almost entirely in the limited API**;
    the only floor-setter is the buffer protocol (`PyObject_GetBuffer` etc.), which
    entered the limited API in **Python 3.11** → abi3 floor 3.11 (fine today).
  - Approach: emit `#define Py_LIMITED_API 0x030B0000` in the shim, use the abi3
    extension suffix (`.abi3.so`) and wheel tag (`cp311-abi3-<plat>`). Gate behind
    `build_wheel(...; abi3=true)`; default could flip later.
  - Files: `cshim.jl` (define + verify every emitted call is limited-API),
    `build.jl` (ext suffix), `wheel.jl` (`_wheel_tag` → abi3 form).
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

- [ ] **4. Shared-runtime wheel** *(size)* — tiny extension wheels that depend on a
  generated `parseltongue-runtime` wheel (vendors libjulia once, Python-agnostic tag).
  `build_runtime_wheel()` + `build_wheel(...; runtime=:shared)`; the package
  `__init__.py` ctypes-preloads libjulia (RTLD_GLOBAL) before importing the ext.
  Reuses `_vendor_libs`/`_pack_wheel`. Effort M–L · Risk M.
- [x] **5. Keyword / default arguments** — `@pyfunc f(a; b=1.0)`; shim uses
  `PyArg_ParseTupleAndKeywords`. `macros.jl` records defaults; `cshim.jl` emits the
  keyword list. Effort M.
- [ ] **6. manylinux tagging** — emit `manylinux_2_xx_<plat>` tags; reconcile with the
  already-bundled libjulia (auditwheel would double-vendor — likely just set the tag
  given a known glibc floor). Effort M · Risk M.
- [ ] **7. macOS support** — `.dylib`, `@loader_path` rpaths, ext suffix; juliac on
  macOS. `build.jl`/`wheel.jl` platform branches. Effort L.
- [ ] **8. More boundary types** — `Bool`/`Int` arrays already work; add `Vector{String}`
  ↔ list[str], and `NamedTuple` ↔ dict return. `boundary.jl` + `cshim.jl`. Effort M each.

## Phase 3 — performance & polish

- [ ] **9. Shrink the bundle** *(size)* — investigate suppressing unused stdlib JLL
  `__init__`s so OpenBLAS/SuiteSparse/networking libs can be dropped (the ~100 MB
  driver). Depends on juliac internals — research/spike. Effort L · Risk M.
- [ ] **10. CI + distribution polish** — GitHub Actions wheel matrix (Python × plat),
  doctest the docs examples, prep for Julia General registry. Effort M.
- [ ] **11. Startup latency** — measure/trim first-call runtime init. Effort S.

## Phase 4 — optional capability track (stateful objects)

- [ ] **12. Opaque-handle types (~scoped `#[pyclass]`)** — a Julia mutable struct kept
  alive behind an opaque pointer/`PyCapsule`; a constructor `@pyfunc` returns a handle,
  methods are `@pyfunc`s taking the handle, with explicit `free`/capsule destructor and
  a GC root registry so Julia doesn't collect it early. Closes the biggest capability
  gap but is a large, higher-risk design. Effort L+ · Risk H · **clearly optional.**

## Cross-cutting conventions

- Spike risky/unknown items in `spike/` before wiring them in (esp. #1 exceptions, #9).
- Every shipped item adds: an example under `examples/`, a unit + integration test,
  and a docs section. Keep the boundary contract and trim-safety invariant.
- Track progress by ticking the checkboxes above across sessions.
