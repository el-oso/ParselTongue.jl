# The `pt` CLI

`pt` is ParselTongue's command-line interface. It wraps
[`build_extension`](/reference/api#Building), [`build_wheel`](/reference/api#Building),
and the startup benchmark so you can compile extensions and wheels without writing
a Julia script or starting a REPL each time.

There are three ways to run it, from quickest-to-set-up to fastest-to-run.

## Running `pt`

### 1. Interpreted (no setup)

Run the CLI straight from the source tree. This starts a fresh Julia session each
time (a few seconds of latency) but needs no build step:

```bash
julia --project=. app/pt.jl build examples/mathx/mathx.jl --outdir=build
```

### 2. As a Pkg App (recommended)

On Julia ≥ 1.12, install `pt` as a [Pkg App](https://pkgdocs.julialang.org/v1/apps/).
This puts a `pt` shim on your `PATH` (at `~/.julia/bin/pt`) that runs
`julia -m ParselTongue`:

```bash
julia -e 'using Pkg; Pkg.Apps.develop(path=".")'
# ensure ~/.julia/bin is on your PATH, then:
pt build examples/mathx/mathx.jl
```

### 3. Compiled binary (fastest)

Compile `pt` itself to a native executable with juliac. The resulting binary has
no Julia-session startup cost:

```bash
julia --project=. app/build_app.jl    # → ./pt
./pt build examples/mathx/mathx.jl
```

All three accept the same commands and options; the examples below use the bare
`pt` form.

## Commands

```
pt build  FILE.jl  [OPTIONS]   Compile a CPython extension (.so)
pt wheel  FILE.jl  [OPTIONS]   Build a pip-installable wheel
pt bench  EXT.so   [OPTIONS]   Measure import + first-call latency
pt version                     Print the version string
pt help                        Show usage
```

### `pt build` — compile an extension

Produces an importable `.so` (the surrounding environment must provide `libjulia`,
e.g. a Julia install on `PATH`). Use this during development.

```bash
pt build mymod.jl --outdir=build
pt build mymod.jl --abi3            # stable-ABI .abi3.so (CPython ≥ 3.11)
```

| Option | Default | Meaning |
|--------|---------|---------|
| `--outdir=DIR` | directory of `FILE` | where to write the `.so` |
| `--mod-name=NAME` | from `@pymodule`, else filename | Python module name |
| `--trim=safe\|unsafe` | `safe` | juliac trim level |
| `--abi3` | off | build a stable-ABI extension |
| `--verbose` | off | print the juliac and `cc` commands |

### `pt wheel` — build a wheel

Produces a pip-installable `.whl`. By default the wheel bundles the Julia runtime
so it imports on a machine with no Julia installed.

```bash
pt wheel mymod.jl --outdir=dist --version=1.0.0
pt wheel mymod.jl --runtime=system          # tiny wheel; needs Julia on target
pt wheel mymod.jl --slim                     # smaller bundle (~38 MB)
pt wheel mymod.jl --emit-pyproject           # also write dist/pyproject.toml
```

| Option | Default | Meaning |
|--------|---------|---------|
| `--outdir=DIR` | `dist` | output directory |
| `--version=X.Y.Z` | `0.1.0` | wheel version |
| `--mod-name=NAME` | from `@pymodule` | Python module name |
| `--trim=safe\|unsafe` | `safe` | juliac trim level |
| `--manylinux=VER\|false` | auto | Linux platform tag (e.g. `2.17`) |
| `--runtime=bundled\|shared\|system` | `bundled` | how the Julia runtime is provided |
| `--slim` | off | vendor only DT_NEEDED libs (bundled only) |
| `--emit-pyproject` | off | write a `pyproject.toml` next to the wheel |
| `--verbose` | off | print commands |

See [Building](/guide/building) for the meaning of `runtime`, `slim`, and
`emit_pyproject`.

### `pt bench` — measure startup

Reports import and first-call latency for a built extension, averaged over fresh
Python processes:

```bash
pt bench build/mathx.cpython-*.so --call="mathx.add(1,2)" --n=5
```

| Option | Default | Meaning |
|--------|---------|---------|
| `--call=EXPR` | none | Python expression to time after import |
| `--n=N` | `5` | number of fresh-process trials |

## Notes

- `pt` covers single-file builds. Multi-module wheels
  ([`build_multi_wheel`](/reference/api#Building)) take several source files and are
  currently driven from Julia, not the CLI.
- Any command run with no positional argument (or `--help` / `-h`) prints its usage
  and exits.
