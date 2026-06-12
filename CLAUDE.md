# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

ParselTongue.jl generates native CPython extensions from plain Julia functions using
`juliac --trim` (Julia ≥ 1.12). A developer annotates functions with `@pyfunc`/`@pymodule`,
runs one build command, and gets an importable module or a self-contained, pip-installable wheel.

## Commands

```bash
# Instantiate (the sole dep, TypeContracts, is an unregistered sibling at ../TypeContracts).
# The Manifest already dev's it; if resolving from scratch:
julia --project=. -e 'using Pkg; Pkg.develop(path="../TypeContracts"); Pkg.instantiate()'

# Run the full test suite (unit + an end-to-end build/import; ~15s)
julia --project=. test/runtests.jl
#   or: julia --project=. -e 'using Pkg; Pkg.test()'

# Run only the fast, build-free unit tests
julia --project=. test/test_m2_boundary_macros.jl

# Build an extension / wheel by hand (what the tests and examples do)
julia --project=. -e 'using ParselTongue; build_extension("examples/mathx/mathx.jl"; outdir="build")'
julia --project=. -e 'using ParselTongue; build_wheel("examples/mathx/mathx.jl"; outdir="dist")'

# Verify a wheel is self-contained: import it with NO Julia in the environment
python3 -c "import zipfile,glob; zipfile.ZipFile(glob.glob('dist/mathx-*.whl')[0]).extractall('/tmp/x')"
env -i HOME="$HOME" PATH="/usr/bin:/bin" PYTHONPATH=/tmp/x python3 -c "import mathx; print(mathx.add(40,2))"

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
user .jl with @pyfunc
  └─ macros.jl     records each export's signature into the build-host registry _EXPORTS
build_extension (build.jl):
  ├─ include the user file in a sandbox module → populates _EXPORTS
  ├─ ccallable_gen.jl  emits a _pt_entry.jl: `using ParselTongue`, include(user), and a
  │                    Base.@ccallable wrapper per export (args/returns are C-ABI carriers)
  ├─ run juliac --output-lib --experimental --trim=safe  → img.a  (trimmed object archive)
  ├─ cshim.jl      emits _<mod>module.c from the SAME export metadata: PyInit_<mod>, a
  │                PyObject↔C wrapper per function, the method table, struct typedefs
  └─ cc -shared: link the C shim + img.a + libjulia → <mod>.<EXT_SUFFIX>.so (one self-contained module)
build_wheel (wheel.jl) additionally:
  ├─ builds the extension as the internal submodule `_<mod>` with $ORIGIN-relative rpaths
  ├─ vendors the Julia runtime into <mod>/julia/lib[/julia] preserving the original layout
  └─ writes __init__.py + dist-info; a generated Python helper computes RECORD and zips the .whl
```

Key point: the `@ccallable` wrappers and the C shim are both generated from ParselTongue's own
macro metadata (`PtExport` in `src/macros.jl`). The shipped 1.12.x `juliac` has **no `--export-abi`**,
and we don't need it — we generate the wrappers, so we already know every signature and struct layout.

## The boundary type system (`src/boundary.jl`)

Every `@pyfunc` argument/return must be a *boundary type*, lowered to a C-ABI "carrier" via three
functions: `c_abi_type(::Type{T})` (the carrier type, build-host only), `from_c(::Type{T}, c)`
(carrier → native), and `to_c(x::T)` (native → carrier). v1 supports scalars, `String` (carrier
`Cstring`), and 1-D numeric `Vector{T}` (carrier `PtBuffer{T}`). The protocol is registered as a
`TypeContracts` `@contract` (`PyBoundary`) so a non-boundary type is rejected at build time with a
clear message rather than a cryptic trim failure (`assert_boundary`).

## Non-obvious constraints — read before changing build/runtime code

- **`from_c`/`to_c` run *inside* the trimmed library**, so they must be trim-safe (type-stable, no
  dynamic dispatch). `c_abi_type` and all of `build.jl`/`cshim.jl`/`wheel.jl` run on the build host
  and have no such restriction.
- **`--trim=safe` rejects any dynamic dispatch reachable from an entrypoint**, and juliac compiles
  every loaded module's `__init__` as an entrypoint. ParselTongue therefore has **no `__init__`** and
  deliberately does **not** depend on `BaseTypeContracts` (its `__init__` registered contracts at
  runtime, which broke trim). Adding a dependency whose `__init__` does dynamic work will break every
  build. Trim-safety is a *static* property — code is rejected even if the bad path is never executed.
- **One ParselTongue extension per Python process.** Each wheel embeds its own `libjulia`; importing
  two such extensions in one process aborts (two Julia runtimes cannot coexist). Co-locate functions
  in one `@pymodule`.
- **The integration test runs the built `.so` in a *subprocess***, never in the test's own Julia — a
  second `libjulia` cannot load into the already-running runtime (`test/test_integration.jl`).
- **Wheels bundle most of `lib/julia`**, excluding only the system image, `libLLVM`, and
  `libjulia-codegen` (`_SKIP_LIB` in `src/wheel.jl`). The stdlib JLL `__init__`s (OpenBLAS, …) run at
  startup and fatally dlopen their libraries even when unused, so they cannot be dropped → ~100 MB wheels.
- **Extension modules do not link `libpython`** — the interpreter provides those symbols at import.
- **juliac requires absolute paths** for its input/output files (`build.jl` uses `abspath`).
- **numpy is never a build dependency.** Array inputs use the buffer protocol; array returns import
  numpy at *runtime* via the generic `PyObject` API (`frombuffer`), falling back to `memoryview`.

## Reference material

- `README.md` — user-facing overview and the same limitation list.
- `docs/` — DocumenterVitepress site (guide + worked examples per boundary kind).
- `spike/` — the Milestone-1 hand-built proof (`add.jl` → trimmed `.so` → `import spikemod`); a minimal
  reference for the raw juliac → PyInit flow.
- `examples/{mathx,strx,arrx}` — scalars, strings, arrays; each builds and imports end-to-end.
