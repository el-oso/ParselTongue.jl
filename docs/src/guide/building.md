# Building

ParselTongue offers two build entry points.

## `build_wheel` — a self-contained, pip-installable wheel

```julia
build_wheel("mymod.jl"; version = "0.2.0", outdir = "dist")
```

Produces `dist/mymod-0.2.0-<pytag>.whl` that bundles the Julia runtime. Install it
with `pip` on any compatible machine — **no Julia required**. This is what you
ship.

The wheel layout:

```
mymod/__init__.py                     re-exports the compiled extension
mymod/_mymod.<EXT_SUFFIX>             the extension (PyInit__mymod)
mymod/julia/lib/libjulia.so.1.x       Julia runtime, original relative layout
mymod/julia/lib/julia/…               preserved so the libs resolve each other
mymod-<ver>.dist-info/{METADATA,WHEEL,RECORD}
```

## `build_extension` — just the extension `.so`

```julia
build_extension("mymod.jl"; outdir = "build")
```

Produces only `build/mymod.<EXT_SUFFIX>` and does **not** bundle libjulia — the
surrounding environment must provide it (its rpath points at the Julia that built
it). Useful for local iteration and testing.

## Options

Both functions accept:

| Keyword | Default | Meaning |
|---------|---------|---------|
| `mod_name` | from `@pymodule`, else the file's base name | Python module name |
| `outdir` | next to the source file | output directory |
| `trim` | `:safe` | `:safe` errors on dynamic dispatch; `:unsafe` / `:unsafe_warn` relax it |
| `python` | `"python3"` | the Python interpreter to target |
| `verbose` | `false` | print the juliac and link commands |

`build_wheel` additionally takes `version` (default `"0.1.0"`), `runtime`
(`:bundled` / `:shared` / `:system`), `slim`, `manylinux`, `abi3`, and
`emit_pyproject`.

### `emit_pyproject` — a publishable project layout

Pass `emit_pyproject=true` to write a minimal PEP 621 `pyproject.toml` next to
the wheel, turning the output directory into a project layout ready for
`twine upload` / PyPI:

```julia
build_wheel("mymod.jl"; version="1.0.0", outdir="dist", emit_pyproject=true)
# dist/mymod-1.0.0-…-linux_x86_64.whl
# dist/pyproject.toml   ← name, version, requires-python, numpy extra
```

`requires-python` is `>=3.11` for `abi3=true` wheels (which run on any CPython ≥
3.11), otherwise the build interpreter's version. A `runtime=:shared` build adds
the `parseltongue-runtime` dependency. The wheel itself is still produced by
juliac — the `pyproject.toml` documents project metadata for publishing tools.
On the CLI: `pt wheel mymod.jl --emit-pyproject`.

### Trim modes

`--trim=safe` (the default) makes juliac **error at build time** if an exported
code path needs dynamic dispatch — the failure is reported as a Julia
stack-frame, before any wheel is produced. If you hit one, the usual fix is to
make the offending function type-stable. As an escape hatch:

```julia
build_wheel("mymod.jl"; trim = :unsafe_warn)   # warns instead of erroring
```

See the [API Reference](/reference/api#Building) for the full docstrings of
[`build_extension`](@ref) and [`build_wheel`](@ref).
