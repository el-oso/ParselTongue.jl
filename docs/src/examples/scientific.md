# A Scientific Module

The `sci` example (`examples/sci/`) brings every type feature together — N-D
arrays (both policies), complex numbers, in-place mutation, void and tuple
returns — and splits the API across **submodules** backed by a single compiled
extension.

## The Julia source

```julia
# sci.jl
using ParselTongue
using LinearAlgebra

@pymodule sci.linalg begin
    @pyfunc matmul(A::AbstractMatrix{Float64}, B::AbstractMatrix{Float64})::Matrix{Float64} = A * B
    @pyfunc rowsums(A::AbstractMatrix{Float64})::Vector{Float64} = vec(sum(A, dims=2))
    @pyfunc normalize(v::Vector{Float64})::Vector{Float64} = v ./ sqrt(sum(abs2, v))
end

@pymodule sci.dsp begin
    @pyfunc conj_sum(z::Vector{ComplexF64})::ComplexF64 = sum(conj, z)
    @pyfunc scale!(x::Mut{Vector{Float64}}, k::Float64)::Nothing = (x .*= k; nothing)
    @pyfunc minmax(v::Vector{Float64})::Tuple{Float64,Float64} = (minimum(v), maximum(v))
end
```

## Build it

```julia
using ParselTongue
build_wheel("sci.jl")
```

```bash
pip install dist/sci-0.1.0-*.whl
```

## Use it from Python

```python
>>> import numpy as np
>>> import sci.linalg as la
>>> import sci.dsp as dsp
>>> A = np.array([[1., 2.], [3., 4.]])
>>> la.matmul(A, np.eye(2)).tolist()
[[1.0, 2.0], [3.0, 4.0]]
>>> la.rowsums(A).tolist()
[3.0, 7.0]
>>> la.normalize(np.array([3., 4.])).tolist()
[0.6, 0.8]
>>> dsp.conj_sum(np.array([1+2j, 3-1j]))
(4-1j)
>>> x = np.array([1., 2., 3.])
>>> dsp.scale(x, 10.0)                   # in place; returns None
>>> x.tolist()
[10.0, 20.0, 30.0]
>>> dsp.minmax(np.array([3., 1., 5.]))
(1.0, 5.0)
```

## Submodules

`@pymodule sci.linalg` / `@pymodule sci.dsp` declare two Python submodules. The
build produces **one** extension holding every function, plus a package:

```
sci/__init__.py            # imports the submodules
sci/linalg.py              # from ._sci import matmul, rowsums, normalize
sci/dsp.py                 # from ._sci import conj_sum, scale, minmax
sci/_sci.<EXT_SUFFIX>      # the single compiled extension (one Julia image)
sci/julia/…                # bundled runtime
```

Because both submodules ride the *same* image, `import sci.linalg` and
`import sci.dsp` coexist in one process — the
[one-extension-per-process](/guide/limitations#One-extension-per-Python-process)
rule only bites genuinely separate extensions. Split your API freely.

::: tip Mutation naming
A Julia `scale!` is exposed to Python as `scale` — the trailing `!` (and any other
non-identifier character) is dropped from the Python name. Pass an explicit name
with `@pyfunc "myname" f(...)` to override.
:::
