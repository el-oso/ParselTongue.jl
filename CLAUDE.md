# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

ParselTongue.jl generates native CPython extensions from plain Julia functions using
`juliac --trim` (Julia ≥ 1.12). A developer annotates functions with `@pyfunc`/`@pymodule`,
runs one build command, and gets an importable module or a self-contained, pip-installable wheel.

## Commands

```bash
# Instantiate
julia --project=. -e 'using Pkg; Pkg.instantiate()'

# Run the full test suite (unit + an end-to-end build/import; ~20s)
julia --project=. test/runtests.jl
#   or: julia --project=. -e 'using Pkg; Pkg.test()'

# Run only the fast, build-free unit tests (~2s)
julia --project=. test/test_m2_boundary_macros.jl

# Build an extension / wheel by hand (what the tests and examples do)
julia --project=. -e 'using ParselTongue; build_extension("examples/mathx/mathx.jl"; outdir="build")'
julia --project=. -e 'using ParselTongue; build_wheel("examples/mathx/mathx.jl"; outdir="dist")'

# Slim wheel (~38 MB instead of ~100 MB; safe for extensions without stdlib JLLs)
julia --project=. -e 'using ParselTongue; build_wheel("examples/mathx/mathx.jl"; slim=true, outdir="dist")'

# System-runtime wheel (~1 MB; requires Julia on target machine)
julia --project=. -e 'using ParselTongue; build_wheel("examples/mathx/mathx.jl"; runtime=:system, outdir="dist")'

# Verify a bundled wheel is self-contained: import it with NO Julia in the environment
python3 -c "import zipfile,glob; zipfile.ZipFile(glob.glob('dist/mathx-*.whl')[0]).extractall('/tmp/x')"
env -i HOME="$HOME" PATH="/usr/bin:/bin" PYTHONPATH=/tmp/x python3 -c "import mathx; print(mathx.add(40,2))"

# Use the pt CLI (runs interpreted; no compile step)
julia --project=. app/pt.jl build examples/mathx/mathx.jl --outdir=build
julia --project=. app/pt.jl wheel examples/mathx/mathx.jl --runtime=system --outdir=dist

# Install pt as a Pkg App (Julia 1.12+; installs shim at ~/.julia/bin/pt)
julia -e 'using Pkg; Pkg.Apps.develop(path=".")'
# then: pt build examples/mathx/mathx.jl

# Build the docs (DocumenterVitepress; needs node/npm). Output in docs/build/
julia --project=docs -e 'using Pkg; Pkg.instantiate()'
julia --project=docs docs/make.jl
```

There is no separate lint step. `build_extension`/`build_wheel` accept `verbose=true` to print
the juliac and `cc` commands, and `keep_build=true` to retain the temp build dir for inspection.

## The build pipeline (the core architecture)

A single `build_extension`/`build_wheel` call runs this pipeline; understanding it requires
reading `src/build.jl`, `src/macros.jl`, `src/ccallable_gen.jl`, and `src/cshim.jl` together:

```
user .jl with @pyfunc / @pymodule / @pyerror / @pyhandle
  └─ macros.jl     records each export's signature into _EXPORTS; errors into _ERRORS
build_extension (build.jl):
  ├─ include the user file in a sandbox module → populates _EXPORTS, _ERRORS
  ├─ ccallable_gen.jl  emits a _pt_entry.jl: `using ParselTongue`, include(user), and a
  │                    Base.@ccallable wrapper per export (args/returns are C-ABI carriers)
  ├─ run juliac --output-lib --experimental --trim=safe  → img.a  (trimmed object archive)
  ├─ cshim.jl      emits _<mod>module.c from the SAME export metadata: PyInit_<mod>, a
  │                PyObject↔C wrapper per function, the method table, struct typedefs,
  │                custom exception globals (from _ERRORS), capsule destructor for handles
  └─ cc -shared: link the C shim + img.a + libjulia → <mod>.<EXT_SUFFIX>.so
build_wheel (wheel.jl) additionally:
  ├─ builds the extension as the internal submodule `_<mod>` with $ORIGIN-relative rpaths
  ├─ runtime=:bundled (default): vendors Julia runtime into <mod>/julia/lib[/julia]
  │     slim=true: only libs reachable via DT_NEEDED BFS (~38 MB vs ~100 MB)
  ├─ runtime=:shared: no vendoring; __init__.py loads runtime from parseltongue-runtime pkg
  ├─ runtime=:system: no vendoring; __init__.py finds Julia on the target machine at import
  └─ writes __init__.py + dist-info; a generated Python helper computes RECORD and zips .whl
```

Key point: the `@ccallable` wrappers and the C shim are both generated from ParselTongue's own
macro metadata (`PtExport` in `src/macros.jl`). The shipped 1.12.x `juliac` has **no `--export-abi`**,
and we don't need it — we generate the wrappers, so we already know every signature and struct layout.

## The boundary type system (`src/boundary.jl`)

Every `@pyfunc` argument/return must be a *boundary type*, lowered to a C-ABI "carrier" via three
functions: `c_abi_type(::Type{T})` (the carrier type), `from_c(::Type{T}, c)` (carrier → native),
and `to_c(x::T)` (native → carrier). Built-in boundary types:

| Julia type | Python type | Carrier |
|---|---|---|
| Scalars (`Int8`–`Int64`, `UInt*`, `Float32/64`, `Bool`, `ComplexF32/64`) | int/float/complex | same scalar |
| `String` | str | `Cstring` |
| `Vector{T}` (numeric) | numpy array / memoryview | `PtArray{T,1}` |
| `Vector{String}` | list[str] | `PtStrArray` |
| `Dict{String,V}` | dict[str,V] | `PtDict{V}` |
| `NamedTuple` | dict | tuple carrier |
| `Union{T,Nothing}` | T or None | `PtOpt{C}` |
| `PtVarArgs{T}` | *args (variadic) | `PtArray{T,1}` |
| `@pyhandle T` (isbits struct) | real Python class (`isinstance`, auto fields, dunders) | `PtHandle{T}` |
| `@pymutable T` (mutable struct, heap fields ok) | mutable Python class via GC registry; live mutation + `__next__` | `PtHandle{T}` (id packed in ptr) |
| `PyCallable` | callable (Float64→Float64) | `Ptr{Cvoid}` |
| User type via `@boundary T carrier=C` | depends on carrier | any existing carrier |

The protocol is registered as a `TypeContracts` `@contract` (`PyBoundary`) so a non-boundary type
is rejected at build time with a clear message rather than a cryptic trim failure (`assert_boundary`).

## `@pyhandle` and `@pymethod` — the real-Python-class system

`@pyhandle T` registers an isbits Julia struct as a real Python type (`PyType_FromSpec`).
Each handle Python object is a `_PtObj_T { PyObject_HEAD; void *_data; }` where `_data`
is a heap-allocated copy of the struct (malloc'd by `to_c`; freed by `_pt_dealloc_T`).
The C carrier is `PtHandle { void *ptr; }`. `from_c(T, h)` = `unsafe_load(Ptr{T}(h.ptr))`.

`@pymethod` attaches a Python dunder to a `@pyhandle` type. Key internals:

| Registry | Location | Purpose |
|---|---|---|
| `_PYMETHOD_SLOTS` | `macros.jl:66` | `dunder → (slot, ret_type)`. `ret_type=nothing` = any boundary type. `slot="Py_tp_richcompare"` for both `__eq__` and `__ne__`. |
| `_PYMETHOD_EXTRA_ARGS` | `macros.jl:78` | Extra arg specs beyond self. `Type[Int64]` for `__getitem__`; `:same_handle` sentinel for `__eq__`/`__ne__` (second arg must be same handle type). |
| `_METHODS` | `macros.jl:103` | `PtMethod[]` — build-host registry. |
| `PtMethod` | `macros.jl:89` | `{handle_type, dunder, jl_func, self_arg, ret}` — no extra args stored; derived from dunder in generators. |

`cabi_symbol(m::PtMethod)` → `"pt_meth_<TypeName>_<clean>"` where `<clean>` strips leading/trailing `__`.

### Supported dunders and their C slots

| Dunder | C slot | Extra arg | C return | Notes |
|---|---|---|---|---|
| `__repr__`, `__str__` | `Py_tp_repr/str` | — | `char*` → `PyUnicode_FromString` | |
| `__len__` | `Py_sq_length` | — | `int64_t` → `Py_ssize_t` | |
| `__hash__` | `Py_tp_hash` | — | `int64_t` → `Py_hash_t` | |
| `__bool__` | `Py_nb_bool` | — | `int8_t` → `int` | |
| `__getitem__` | `Py_sq_item` | `Int64` index (`Py_ssize_t` → `int64_t`) | any boundary → `PyObject*` | Integer indices only; slices need `Py_mp_subscript` |
| `__setitem__` | `Py_sq_ass_item` | `Int64` index + value | `void` (write-back via `unsafe_store!`) | Returns new `T`; ccallable stores it back |
| `__contains__` | `Py_sq_contains` | one boundary value | `int8_t` → `int` | `PyArg_Parse` unbox |
| `__call__` | `Py_tp_call` | any boundary args (tuple) | any boundary → `PyObject*` | `PyArg_ParseTuple` |
| `__iter__` | `Py_tp_iter` | — | self | Pure C `Py_INCREF(self); return self` (no Julia call) |
| `__next__` | `Py_tp_iternext` | — | `PtOpt` (`Union{V,Nothing}`) | `has_value==0` → `PyErr_SetNone(StopIteration)`; advance state in place (`@pymutable`) |
| `__enter__`, `__exit__` | `Py_tp_methods` (PyMethodDef) | — | self / `int8_t` | NOT type slots — go in the method table |
| `__add__`,`__sub__`,`__mul__`,`__truediv__`,`__floordiv__`,`__mod__`,`__pow__`,`__matmul__` (+ `__r*__` reflected) | `Py_nb_*` (binary) | same handle **or** scalar (`:numeric_other`) | any boundary → `PyObject*` | Forward + reflected for one slot share ONE combined wrapper (grouped like richcmp); dispatches on operand types — T×T, T×scalar, scalar×T. Scalar parse failure → `PyErr_Clear` + `NotImplemented` (mixed-type fallback). `__pow__`/`__rpow__` ternaryfunc (modulo ignored) |
| `__neg__`,`__pos__`,`__abs__`,`__invert__` | `Py_nb_*` (unary) | — | any boundary → `PyObject*` | Per-method wrapper (no dispatch) |
| `__eq__`, `__ne__`, `__lt__`, `__le__`, `__gt__`, `__ge__` | `Py_tp_richcompare` (shared) | same handle type → `PtHandle{T}` | `int8_t` → `PyBool_FromLong` | Single `_pt_richcmp_T`; `__eq__`↔`__ne__` auto-derived (negation); ordering ops return `NotImplemented` when not registered (Python handles reflection) |
| *(named)* `@pymethod foo(self::T, …)` | `Py_tp_methods` (PyMethodDef) | any boundary args (tuple) | any boundary / `Nothing`→`None` | One-arg `@pymethod` form (non-dunder name) → bound `obj.foo(args)` via `PtNamedMethod`; METH_VARARGS PyCFunction |

`@pymethod` two-arg form is dunder-only; the one-arg form (plain name) registers a bound named
method (`PtNamedMethod`, `_NAMED_METHODS`). `is_numeric_binary`/`is_numeric_reflected`/`is_numeric_unary`
(`macros.jl`) classify the number-protocol slots; binary+reflected are grouped per `Py_nb_*` slot in
`cshim.jl`. The C-ABI carrier struct typedefs (array/opt/dict/tuple) are emitted by `emit_cshim`
**before** `_emit_handle_type_defs`, because slot wrappers (e.g. `__next__`'s `PtOpt`, `__getitem__`'s
return, named-method args) reference them; the carrier set is collected from exports **and**
method/`__new__`/property/named-method signatures via `_carrier_set`.

### RAII scope guards in the generated C (`__attribute__((cleanup))`)

Generated wrappers acquire heap resources in `ArgPlan.setup`. They formerly unwound them by hand
on every `return NULL` (via a `_insert_cleanup_before_return` rewriter), the error-prone pattern
that caused the A1/A2 leak fixes. **Every heap-acquiring argument carrier now uses a compiler scope
guard instead** — the technique the Linux kernel borrowed from Rust (`cleanup.h`). Each carrier is
declared `__attribute__((cleanup(<guard>)))` so the compiler releases it on *any* scope exit, and
the setup code is plain `return NULL` with no manual frees. The guards (all `static` helpers):

| carrier | builder | guard | release | disarm? |
|---|---|---|---|---|
| `Dict{String,V}` | `_ap_dict` | `_pt_dictguard_<C>` (by `_dict_structs`) | `free` keys/vals | **yes** |
| `Vector{T}` numeric | `_ap_array` | `_pt_bufferguard` | `PyBuffer_Release` | no |
| `Vector{String}` | `_ap_stra` | `_pt_strarrayguard` | `_pt_free_str_array` | no |
| `PyCallable` | `_ap_pycallable` | `_pt_callableguard` | `Py_XDECREF` | no |

**Disarm (`ArgPlan.disarm`).** Only the dict transfers ownership to the Julia callee (`from_c`
frees it on success), so its guard must be **disarmed** after the call — NULL the carrier fields,
emitted right after `Py_END_ALLOW_THREADS` in `_wrapper_fn`/`_wrapper_fn_varargs` **and** in the
`@pymethod`/`@pynew`/named-method wrappers (`_emit_tp_new_slot` etc.). `disarm` runs *only*
post-call, never on error paths. The other three carriers are always-release (no disarm): the
guard fires on success and every error path alike. This is Rust's "borrow checker, pass it to the
owner" idiom; it also closed a latent leak (a *later* arg failing before the call) and a latent
double-free (dict args in method wrappers, which lacked the disarm).

`_insert_cleanup_before_return` and the per-arg `cleanup`-threading are **retired** — the guards
made them dead. `ArgPlan.cleanup` is now effectively reserved (only the handle method/`__new__`
wrappers still emit it, and it is empty). Compiler support: gcc/clang/MinGW (all supported targets;
MSVC is not). Validated under ASan/LSan in `test/asan/` (dict-arg `take` + strarray-arg `take_strs`
fixtures + driver, success + error paths, teeth-checked); the refcount-based buffer/PyCallable
paths are covered by the integration refleak gate.

**Julia-side analogue — the `PyCallable` call operator (`boundary.jl`).** The same
"release on scope exit" idiom applies on the Julia side, where there is no `Drop`/`cleanup`
attribute: the `@generated (f::PyCallable{Args,Ret})(args...)` operator re-acquires the GIL
(`PyGILState_Ensure`) then wraps its whole body in **one `try/finally`**. The `finally`
drops the GIL, the argument tuple, and the call result on *every* exit — success, a
Python-side exception, and a Julia-side throw (`convert(Ti,…)` `InexactError`,
`_py_unbox(Ret,…)` allocation). This replaced five hand-written `PyGILState_Release` sites
that skipped the throw paths (a latent GIL leak — process-wide hazard — plus a `result`
refcount leak). Do **not** revert to per-path releases. ErrorTypes.jl (Rust-style `Result`)
was evaluated for this and **declined**: the guarantee is a *cleanup* concern (Rust gets it
from `Drop`, not `Result`; Julia's analogue is `try/finally`), and without `#[must_use]` a
Julia `Result` adds no enforcement — see `docs/src/guide/vs-pyo3.md` (GIL management) and the
unmerged `spike/errortypes` branch. The exception path is gated by an error-path refleak
case in `test/fixtures/feature_script.py` (`_no_refleak_raises`).

### Python subclassing (`subclass=` / `dict=`, PyO3-style opt-in flags)

`@pyhandle T subclass=true` / `@pymutable T subclass=true` add `Py_TPFLAGS_BASETYPE` and a
subclass-aware `tp_new` (allocates with the passed `type`, not the hardcoded base, so
`class Sub(T)` instances are real `Sub` objects). A pure-Python subclass inherits
the constructor/fields/methods/dunders and may add methods, properties, and dunder overrides.

**`subclass=true` ⟹ the dict slot** (`has_dict = (T in _DICT_TYPES) || is_subclassable`,
`cshim.jl`). This is load-bearing, not cosmetic: a pure-Python subclass *always* gets a
`__dict__`, and on CPython ≥3.12 a subclass of a type **without** `tp_dictoffset` is given a
**managed dict** whose inline values overlap our `_data` field (offset 16, after
`PyObject_HEAD`) — `free(self->_data)` in dealloc then frees a clobbered interior pointer →
heap corruption → intermittent SIGSEGV (deterministic on 3.12, latent on 3.14). Giving the
base a classic `tp_dictoffset` makes subclasses inherit the classic slot instead. See
[[subclass-managed-dict-crash]].

`dict=true` (PyO3 `#[pyclass(dict)]`) gives instances a real `__dict__`; subclassable types
get the same machinery automatically. We use the **classic explicit-`tp_dictoffset`**
mechanism (version-stable across 3.11–3.14), NOT the managed-dict pre-header: the instance
struct gains a `PyObject *_dict` field, exposed as `tp_dictoffset` via the `__dictoffset__`
special member that `PyType_FromSpec` recognises, plus a `__dict__` getset
(`PyObject_GenericGetDict`/`SetDict`). An object holding arbitrary Python refs must collect
cycles, so dict types are GC types: `Py_TPFLAGS_HAVE_GC` + `tp_traverse`/`tp_clear`
(`Py_VISIT`/`Py_CLEAR` on `_dict`) + `PyObject_GC_UnTrack` in dealloc + `tp_free`. Crucial
gotcha: **`PyType_GenericAlloc` already GC-tracks**, so we must NOT call `PyObject_GC_Track`
(doing so trips `_PyObject_AssertFailed`). The dealloc fetches `tp_free` via
`PyType_GetSlot(Py_TYPE(self), Py_tp_free)` (limited-API safe; handles a GC subclass's
differing `tp_free`) rather than `Py_TYPE(self)->tp_free`, so subclassable types build under
`abi3=true`. Explicit `dict=true` still errors with `abi3=true` (`build_extension` guard on
`_DICT_TYPES`).

Flags live in `_SUBCLASS_TYPES` / `_DICT_TYPES`, threaded via the `_preloaded` NamedTuple
(`_registry_snapshot`). Native inheritance between ParselTongue types (PyO3 `extends=`) is
unsupported — Julia structs can't share a C layout.

### How `cshim.jl` generates richcmp

In `_emit_handle_type_defs` (`cshim.jl:1061`):
- The `for m in tmeths` loop **skips** `__eq__`/`__ne__` (they need no individual slot wrappers).
- After the loop, if any eq/ne registered: emit `extern int8_t ...` declarations + one
  `_pt_richcmp_T(PyObject *self, PyObject *other, int op)` that type-checks `other` via
  `Py_TYPE(other) != (PyTypeObject *)_PtType_T → Py_RETURN_NOTIMPLEMENTED`, then dispatches
  on `op`. If only `__eq__`: `op == Py_NE) r = !r`. If only `__ne__`: `op == Py_EQ) r = !r`.
- The slot array loop also skips `__eq__`/`__ne__` and adds ONE `{Py_tp_richcompare, ...}` entry.

**Ordering reflection**: Python automatically tries the reflected operation (e.g. `a > b` calls
`b.__lt__(a)`) when `__gt__` returns `NotImplemented`. So defining only `__lt__`/`__le__`
covers all four comparison directions for same-type objects.

**Hash/eq interaction**: defining `__eq__` without `__hash__` makes the type unhashable
(CPython's `type_ready` sets `tp_hash = PyObject_HashNotImplemented` when `tp_richcompare`
is set but `tp_hash` is not). Register `@pymethod __hash__` alongside `__eq__` to retain hashability.

## `@pymutable` — mutable classes via a GC registry (`boundary.jl`)

`@pymutable T` registers a **`mutable struct`** (heap fields like `String`/`Vector` allowed) as a
real, mutable Python class. It reuses the `PtHandle{T}` carrier but packs a registry **id** (Int64)
into the pointer slot instead of a malloc'd struct pointer. The macro (in the user file, so it has
lexical access to the registry) emits, at file/global scope:

- `const _PtRegistry_T = Dict{Int64,T}()` + `const _PtIdSeq_T = Ref{Int64}(0)` — the GC root.
- `to_c(obj)::PtHandle{T}` → increments the seq, stores `obj`, packs the id. `from_c(T, h)` →
  `_PtRegistry_T[id]` (the **live** object, not a copy — mutations persist).
- `Base.@ccallable _pt_dealloc_T_jl(h)::Cvoid` → `delete!(_PtRegistry_T, id)` (called from
  C `tp_dealloc`, releasing the reference for Julia GC).

All ops are concrete-typed, so they stay trim-safe. A `@pymutable` type is registered in **both**
`_HANDLE_TYPES` (it needs a `PyTypeObject`) and `_MUTABLE_STRUCT_TYPES` (marks the registry-backed
codegen path). In `_emit_handle_type_defs`, `is_mut_struct = T in mutable_struct_types` branches:
the dealloc calls the Julia ccallable (not `free`), and scalar/`String` fields are exposed
read/write via per-field getter/setter `@ccallable`s (`pt_field_get_T_f` / `pt_field_set_T_f`,
emitted by `emit_ccallable_field_accessors`) routed through `Py_tp_getattro`/`Py_tp_setattro` —
**not** raw memory reads, since fields may be non-isbits.

Because `__new__`, `@pymethod`s, and `@pyfunc` args/returns all go through the shared `PtHandle`
plumbing, only `to_c`/`from_c`/dealloc/field-access differ from `@pyhandle`. Mutating methods can be
bound (`@pymethod bump!(c::T, …)` → `c.bump()`) or module-level (`@pyfunc f(c::T, …)` → `mod.f(c)`);
both mutate the live registry object. Stateful iterators are the canonical use:
`@pymethod __iter__ (self-return)` + `@pymethod __next__ (::Union{V,Nothing})`.

All build-host registries are snapshotted into the `_preloaded` NamedTuple (`_registry_snapshot`,
`macros.jl`) and threaded into `emit_entry`/`emit_cshim` (`mutable_struct_types`, `named_methods`,
`subclass_types`, `dict_types`, …).

## The CLI (`app/pt.jl`, `src/cli.jl`)

`src/cli.jl` is included by `src/ParselTongue.jl` and defines `julia_main()` inside the module.
This enables two invocation paths:

1. **Interpreted** (development): `julia --project=. app/pt.jl build FILE.jl`
   `app/pt.jl` is a 2-line wrapper: `using ParselTongue: julia_main`
2. **Compiled binary**: `julia --project=. app/build_app.jl` → `./pt` (juliac, `--trim=unsafe`)
3. **Pkg App** (Julia 1.12+): `julia -e 'using Pkg; Pkg.Apps.develop(path=".")` installs
   `~/.julia/bin/pt` which runs `julia -m ParselTongue [args]` → calls `ParselTongue.julia_main()`

## Non-obvious constraints — read before changing build/runtime code

- **`from_c`/`to_c` run *inside* the trimmed library**, so they must be trim-safe (type-stable, no
  dynamic dispatch). `c_abi_type` and all of `build.jl`/`cshim.jl`/`wheel.jl` run on the build host
  and have no such restriction.
- **`--trim=safe` rejects any dynamic dispatch reachable from an entrypoint**, and juliac compiles
  every loaded module's `__init__` as an entrypoint. ParselTongue therefore has **no `__init__`**.
  TypeContracts itself also has no `__init__`, so it is safe. Adding a dependency whose `__init__`
  does dynamic work will break every build. Trim-safety is a *static* property — code is rejected
  even if the bad path is never executed.
- **One ParselTongue extension per Python process.** Each wheel embeds its own `libjulia`; importing
  two such extensions in one process aborts (two Julia runtimes cannot coexist). Co-locate functions
  in one `@pymodule`. (`runtime=:shared` / `:system` extensions share one runtime and are safe to
  combine, but only one `libjulia` can be in-process at a time.)
- **The integration test runs the built `.so` in a *subprocess***, never in the test's own Julia — a
  second `libjulia` cannot load into the already-running runtime (`test/test_integration.jl`).
- **Bundled wheels include most of `lib/julia`** (~100 MB), excluding the system image, `libLLVM`,
  and `libjulia-codegen` (`_SKIP_LIB` in `src/wheel.jl`). `slim=true` reduces this to ~38 MB via
  DT_NEEDED BFS but breaks stdlib JLL users. `runtime=:system` / `:shared` skip vendoring entirely.
- **Extension modules do not link `libpython`** — the interpreter provides those symbols at import.
- **juliac requires absolute paths** for its input/output files (`build.jl` uses `abspath`).
- **numpy is never a build dependency.** Array inputs use the buffer protocol; array returns import
  numpy at *runtime* via the generic `PyObject` API (`frombuffer`), falling back to `memoryview`.
- **`runtime=:system` PATH fallback spawns a subprocess** (`julia -e 'print(Sys.BINDIR)'`) at first
  import to locate juliaup-managed installations. This is slow (~2 s) but only runs once and only
  when `JULIA_BINDIR`/`JULIA_PREFIX` are not set. CI/containers should set `JULIA_BINDIR`.
- **Windows support targets MinGW-w64 (gcc)**. MSVC (`cl.exe`) is not yet supported. On Windows,
  Julia DLLs live in `bin/` (not `lib/`); bundled wheels vendor from `Sys.BINDIR`. Extension
  `.pyd` files must link the Python DLL explicitly (`_py_lib_flags`). DLL resolution uses
  `os.add_dll_directory()` (Python 3.8+) in `__init__.py` instead of rpaths. The
  `_current_os_kernel()` helper parameterises `__init__.py` generation so Windows paths can be
  unit-tested on Linux by passing `_os_kernel=:windows` to the `_write_*` functions.
- **`_find_cc` on Windows probes clang's target triple** (`build.jl:_clang_is_mingw`) before
  accepting it. Standalone LLVM clang on Windows targets MSVC by default and does not accept
  `-Wl,--whole-archive`; only MinGW/MSYS2 clang (triple contains `mingw` or `w64`) is accepted.
  `JULIA_CC` bypasses this check.
- **`slim=true` on Windows requires `objdump`** — part of the MinGW-w64 toolchain; not available
  with standalone LLVM clang.
- **TrimFailure diagnostics**: juliac output is captured in `_run_juliac`; on failure,
  `TypeContracts.explain_trim_failure` parses `Verifier error #N:` blocks and throws a
  source-mapped `TrimFailure` instead of a raw process error. `verbose=true` also prints the
  raw output.

## Reference material

- `README.md` — user-facing overview and limitation list.
- `docs/` — DocumenterVitepress site (guide + worked examples per boundary kind).
- `spike/` — the Milestone-1 hand-built proof (`add.jl` → trimmed `.so` → `import spikemod`); a minimal
  reference for the raw juliac → PyInit flow.
- `examples/{mathx,strx,arrx}` — scalars, strings, arrays; each builds and imports end-to-end.
- `app/pt.jl` — thin juliac wrapper (2 lines); `app/build_app.jl` — compile the `pt` binary.
- `src/cli.jl` — full `pt` CLI implementation; included by `src/ParselTongue.jl`.
