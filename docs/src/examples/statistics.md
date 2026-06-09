# A Statistics Module

A slightly larger, self-contained example: a `stats` module that combines
scalars, strings, and arrays in one extension. It also illustrates the
[one-extension-per-process](/guide/limitations#One-extension-per-Python-process)
rule — everything you want to use together lives in a single module.

## The Julia source

```julia
# stats.jl
using ParselTongue

mean(v) = sum(v) / length(v)

function variance(v)
    m = mean(v)
    s = 0.0
    for x in v
        s += (x - m)^2
    end
    return s / length(v)
end

@pymodule stats begin

    @pyfunc mean_f64(v::Vector{Float64})::Float64 = mean(v)

    @pyfunc std_f64(v::Vector{Float64})::Float64 = sqrt(variance(v))

    @pyfunc function normalize(v::Vector{Float64})::Vector{Float64}
        m = mean(v)
        s = sqrt(variance(v))
        return (v .- m) ./ s
    end

    @pyfunc function describe(v::Vector{Float64})::String
        return string("n=", length(v),
                      " mean=", round(mean(v); digits = 3),
                      " std=",  round(sqrt(variance(v)); digits = 3))
    end

end
```

Note that helper functions (`mean`, `variance`) need **no** annotation — only the
functions you expose to Python get `@pyfunc`. They must still be trim-safe
(type-stable), which these are.

## Build it

```julia
using ParselTongue
build_wheel("stats.jl")
```

```bash
pip install dist/stats-0.1.0-*.whl
```

## Use it from Python

```python
>>> import stats, numpy as np
>>> x = np.array([2.0, 4.0, 4.0, 4.0, 5.0, 5.0, 7.0, 9.0])
>>> stats.mean_f64(x)
5.0
>>> stats.std_f64(x)
2.0
>>> stats.normalize(x)
array([-1.5, -0.5, -0.5, -0.5,  0. ,  0. ,  1. ,  2. ])
>>> stats.describe(x)
'n=8 mean=5.0 std=2.0'
```

## Why one module?

If `mean_f64` lived in a `means` wheel and `std_f64` in a `stds` wheel, you could
not `import means` and `import stds` in the same Python session — each wheel
carries its own `libjulia`, and two runtimes abort the process. Co-locating
related functions in one `@pymodule` is the v1 way to ship them together.
