# Scalars

The `mathx` example (`examples/mathx/`) exposes integer, float, and boolean
functions, and shows how to give a function a different Python name.

## The Julia source

```julia
# mathx.jl
using ParselTongue

@pymodule mathx begin

    @pyfunc add(a::Int64, b::Int64)::Int64 = a + b

    @pyfunc function fma2(x::Float64, y::Float64, z::Float64)::Float64
        return x * y + z
    end

    @pyfunc is_even(n::Int64)::Bool = iseven(n)

    # Export under a different Python name with a leading string literal.
    @pyfunc "scale" scale_f32(v::Float32, k::Float32)::Float32 = v * k

end
```

Things to notice:

- Both the short form `f(...) = ...` and the `function … end` form work.
- `@pyfunc "scale" scale_f32(...)` exports the Julia function `scale_f32` to
  Python as `scale`.
- Supported scalar types: `Int8`–`Int64`, `UInt8`–`UInt64`, `Bool`, `Float32`,
  `Float64`.

## Build it

```julia
using ParselTongue
build_wheel("mathx.jl")
```

```bash
pip install dist/mathx-0.1.0-*.whl
```

## Use it from Python

```python
>>> import mathx
>>> mathx.add(40, 2)
42
>>> mathx.fma2(2.0, 3.0, 4.0)      # 2*3 + 4
10.0
>>> mathx.is_even(10), mathx.is_even(7)
(True, False)
>>> mathx.scale(1.5, 2.0)          # scale_f32, renamed
3.0
```

Scalars are their own C carrier, so these wrappers compile down to a direct call
into the trimmed Julia — there is no marshalling overhead beyond the Python
argument parse.
