```@raw html
---
layout: home

hero:
  name: ParselTongue.jl
  text: Python extensions written in Julia
  tagline: Annotate plain Julia functions with one macro, run one build command, ship a pip-installable wheel. No Rust, no PyO3, no hand-written C.
  actions:
    - theme: brand
      text: Get Started
      link: /guide/getting-started
    - theme: alt
      text: Examples
      link: /examples/scalars
    - theme: alt
      text: API Reference
      link: /reference/api

features:
  - title: One macro, plain Julia
    icon: 🐍
    details: "Write ordinary Julia and mark exports with @pyfunc. ParselTongue generates the C-ABI wrappers and the CPython PyInit shim for you — less friction than Rust + PyO3."
  - title: Self-contained wheels
    icon: 📦
    details: "build_wheel bundles the Julia runtime into a pip-installable wheel. End users run `pip install` and `import` — no Julia installation required."
  - title: Transparent NumPy
    icon: 🔢
    details: "Pass any buffer (NumPy, array.array, memoryview) zero-copy; array returns come back as numpy.ndarray when NumPy is present. NumPy is never a build dependency."
  - title: Trimmed & native
    icon: ⚡
    details: "Compiled with juliac --trim into a small C-ABI library and a real CPython extension. import mymod; mymod.f(x) calls straight into compiled Julia."
  - title: Build-time safety
    icon: 🔒
    details: "Argument and return types are validated against a TypeContracts contract at build time — a non-boundary type is a clear error, not a cryptic trim failure."
---
```

## What is ParselTongue.jl?

ParselTongue turns Julia functions into native Python extensions. You write plain
Julia, annotate the functions you want to expose, and run one command to get an
importable module — or a self-contained wheel that needs no Julia on the user's
machine.

```julia
# mathx.jl
using ParselTongue

@pymodule mathx begin
    @pyfunc add(a::Int64, b::Int64)::Int64        = a + b
    @pyfunc greet(name::String)::String           = "Hello, " * name * "!"
    @pyfunc sum_f64(xs::Vector{Float64})::Float64 = sum(xs)
end
```

```julia
using ParselTongue
build_wheel("mathx.jl")          # -> dist/mathx-0.1.0-cp3xx-…-linux_x86_64.whl
```

```bash
pip install dist/mathx-0.1.0-*.whl   # no Julia needed on this machine
python -c "import mathx; print(mathx.add(40, 2), mathx.greet('World'))"
# 42 Hello, World!
```

## How it works

```
@pyfunc  ─►  generated Base.@ccallable wrappers (Julia, C-ABI carriers)
         ─►  juliac --output-lib --experimental --trim=safe  ─►  img.a (trimmed)
         ─►  generated _<mod>module.c  (PyInit + PyObject↔C marshalling)
         ─►  cc -shared: shim + img.a + libjulia  ─►  <mod>.<ext>.so
         ─►  wheel: __init__.py + .so + julia/ runtime  (rpath $ORIGIN/julia/lib…)
```

The Julia `@ccallable` wrappers and the C shim are generated from ParselTongue's
own macro metadata. Boundary-type validation reuses
[TypeContracts.jl](https://github.com/el_oso/TypeContracts.jl).

## Requirements

- Julia ≥ 1.12 with the bundled `juliac` (e.g. via [`juliaup`](https://github.com/JuliaLang/juliaup)).
- A C compiler (`cc`/`gcc`/`clang`) and `python3` with development headers.

See [Getting Started](/guide/getting-started) to build your first extension, or
jump to the [Examples](/examples/scalars).
```@meta
```
