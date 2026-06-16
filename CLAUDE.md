# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

ParselTongue.jl generates native CPython extensions from plain Julia functions using
`juliac --trim` (Julia ≥ 1.12). A developer annotates functions with `@pyfunc`/`@pymodule`,
runs one build command, and gets an importable module or a self-contained, pip-installable wheel.

## Commands

```bash
# Instantiate — TypeContracts is resolved via the [sources] URL in Project.toml.
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
| `__eq__`, `__ne__` | `Py_tp_richcompare` (shared) | same handle type → `PtHandle{T}` | `int8_t` → `PyBool_FromLong` | Single `_pt_richcmp_T` C function; cross-type → `NotImplemented`; `__ne__` auto-derived from `__eq__` if only one registered |

### How `cshim.jl` generates richcmp

In `_emit_handle_type_defs` (`cshim.jl:1061`):
- The `for m in tmeths` loop **skips** `__eq__`/`__ne__` (they need no individual slot wrappers).
- After the loop, if any eq/ne registered: emit `extern int8_t ...` declarations + one
  `_pt_richcmp_T(PyObject *self, PyObject *other, int op)` that type-checks `other` via
  `Py_TYPE(other) != (PyTypeObject *)_PtType_T → Py_RETURN_NOTIMPLEMENTED`, then dispatches
  on `op`. If only `__eq__`: `op == Py_NE) r = !r`. If only `__ne__`: `op == Py_EQ) r = !r`.
- The slot array loop also skips `__eq__`/`__ne__` and adds ONE `{Py_tp_richcompare, ...}` entry.

**Hash/eq interaction**: defining `__eq__` without `__hash__` makes the type unhashable
(CPython's `type_ready` sets `tp_hash = PyObject_HashNotImplemented` when `tp_richcompare`
is set but `tp_hash` is not). Register `@pymethod __hash__` alongside `__eq__` to retain hashability.

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

## Reference material

- `README.md` — user-facing overview and limitation list.
- `docs/` — DocumenterVitepress site (guide + worked examples per boundary kind).
- `spike/` — the Milestone-1 hand-built proof (`add.jl` → trimmed `.so` → `import spikemod`); a minimal
  reference for the raw juliac → PyInit flow.
- `examples/{mathx,strx,arrx}` — scalars, strings, arrays; each builds and imports end-to-end.
- `app/pt.jl` — thin juliac wrapper (2 lines); `app/build_app.jl` — compile the `pt` binary.
- `src/cli.jl` — full `pt` CLI implementation; included by `src/ParselTongue.jl`.
