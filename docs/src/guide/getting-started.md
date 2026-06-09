# Getting Started

This guide takes you from an empty file to an installed, importable Python module
backed by compiled Julia.

## Prerequisites

- **Julia ≥ 1.12** with the bundled `juliac` compiler. The easiest way is
  [`juliaup`](https://github.com/JuliaLang/juliaup):
  ```bash
  juliaup add 1.12
  ```
- A **C compiler** (`cc`, `gcc`, or `clang`) on your `PATH`.
- **`python3`** with development headers (the `Python.h` from `python3-dev` /
  `python3-devel`).

## Install ParselTongue

```julia
using Pkg
Pkg.add(url = "https://github.com/el_oso/ParselTongue.jl")
```

## 1. Write some Julia

Create `greeter.jl`. Mark each function you want to expose with [`@pyfunc`](@ref),
and group them with [`@pymodule`](@ref) to name the Python module:

```julia
# greeter.jl
using ParselTongue

@pymodule greeter begin
    @pyfunc function shout(name::String)::String
        return uppercase(name) * "!"
    end

    @pyfunc repeat_sum(n::Int64)::Int64 = sum(1:n)
end
```

Every argument and return type must be a [boundary type](/guide/boundary-types)
(scalars, `String`, or 1-D numeric `Vector`s in v1). The function stays callable
from Julia, so you can test it normally before building.

## 2. Build a wheel

```julia
using ParselTongue
build_wheel("greeter.jl")
```

This compiles the trimmed Julia library, generates the CPython shim, links the
extension, and bundles the Julia runtime into a wheel under `dist/`:

```
dist/greeter-0.1.0-cp312-cp312-linux_x86_64.whl
```

See [Building](/guide/building) for `build_extension` (a bare `.so`, no bundled
runtime) and the available options.

## 3. Install and use it

```bash
pip install dist/greeter-0.1.0-*.whl
```

```python
>>> import greeter
>>> greeter.shout("world")
'WORLD!'
>>> greeter.repeat_sum(100)
5050
```

The wheel is self-contained — it works on a machine with **no Julia installed**.

## What just happened?

```
greeter.jl
  └─ @pyfunc records each signature
build_wheel
  ├─ generates Base.@ccallable wrappers
  ├─ juliac --trim=safe  → trimmed object archive (img.a)
  ├─ generates _greeter module.c (PyInit + marshalling)
  ├─ links shim + img.a + libjulia → greeter extension .so
  └─ bundles libjulia + writes the wheel
```

Continue with [Boundary Types](/guide/boundary-types) to see exactly what can
cross the Julia ↔ Python boundary.
