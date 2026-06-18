# Callbacks & Errors

Two features that make a module feel native to Python: accepting **Python callables**
as arguments, and raising **typed Python exceptions**.

## Calling back into Python: `PyCallable`

A `@pyfunc` can take a Python callable as an argument and invoke it from Julia.
The type parameter `PyCallable{Args, Ret}` declares the signature; the bare name
`PyCallable` is shorthand for `Float64 → Float64`:

```julia
# numkit.jl
using ParselTongue

@pymodule numkit begin
    # f: Float64 -> Float64
    @pyfunc apply(f::PyCallable, x::Float64)::Float64 = f(x)

    # A real use: bisection root-finder driven by a Python function.
    @pyfunc bisect(f::PyCallable, lo::Float64, hi::Float64)::Float64 = begin
        for _ in 1:52
            mid = (lo + hi) / 2.0
            f(mid) < 0.0 ? (lo = mid) : (hi = mid)
        end
        (lo + hi) / 2.0
    end

    # Other signatures: (Int64, Int64) -> Int64
    @pyfunc combine(f::PyCallable{Tuple{Int64,Int64},Int64}, a::Int64, b::Int64)::Int64 = f(a, b)

    # String and Vector signatures are supported too.
    @pyfunc apply_str(f::PyCallable{Tuple{String},String}, s::String)::String = f(s)
    @pyfunc apply_vec(f::PyCallable{Tuple{Vector{Float64}},Vector{Float64}},
                      v::Vector{Float64})::Vector{Float64} = f(v)
end
```

From Python you pass any callable — a `lambda`, a `def`, or a builtin:

```python
>>> import numkit
>>> numkit.apply(lambda x: x * 2.0, 3.0)
6.0
>>> numkit.apply(abs, -5.0)
5.0
>>> round(numkit.bisect(lambda x: x**2 - 2.0, 1.0, 2.0), 6)   # √2
1.414214
>>> numkit.combine(lambda a, b: a + b, 3, 4)
7
>>> numkit.apply_str(str.upper, "hello")
'HELLO'
>>> numkit.apply_vec(sorted, [3.0, 1.0, 2.0])
[1.0, 2.0, 3.0]
```

Supported callback argument/return types are scalars, `String` (↔ `str`), and
`Vector{T}` for scalar `T` (↔ `list`). Each call re-acquires the GIL, boxes the
arguments, invokes the callable, and unwraps the result — releasing the GIL and
every temporary reference on all paths (see the
[GIL discussion](/guide/vs-pyo3#GIL-management)).

## Raising Python exceptions

By default, any Julia `error(...)` (or other thrown exception) surfaces in Python
as a `RuntimeError`:

```julia
@pymodule numkit begin
    @pyfunc checked_inv(x::Float64)::Float64 =
        x == 0.0 ? error("cannot invert zero") : 1.0 / x
end
```

```python
>>> numkit.checked_inv(0.0)
Traceback (most recent call last):
  ...
RuntimeError: cannot invert zero
```

To map specific Julia exception types onto specific Python exception classes,
register them with `@pyerror` before the module. Use the Julia type's name; add
`<: Parent` to choose the Python base class (default `Exception`):

```julia
using ParselTongue

@pyerror DomainError                 # → numkit.DomainError   <: Exception
@pyerror ArgumentError <: ValueError # → numkit.ArgumentError <: ValueError

@pymodule numkit begin
    @pyfunc sqrt_checked(x::Float64)::Float64 =
        x < 0.0 ? throw(DomainError(x, "negative input")) : sqrt(x)

    @pyfunc nth_root(x::Float64, n::Int64)::Float64 =
        n <= 0 ? throw(ArgumentError("n must be positive")) : x^(1.0 / n)
end
```

The registered types become real classes on the module, so Python can catch them
precisely — and `ArgumentError`, being declared `<: ValueError`, is caught by an
`except ValueError` too:

```python
>>> import numkit
>>> try:
...     numkit.sqrt_checked(-1.0)
... except numkit.DomainError as e:
...     print("domain:", e)
domain: negative input
>>> try:
...     numkit.nth_root(8.0, 0)
... except ValueError as e:          # ArgumentError <: ValueError
...     print("value:", e)
value: n must be positive
```

The error code is packed into an out-parameter and decoded by the generated C
shim into the right `PyErr_SetString` call — no dynamic Python-object creation
happens inside the trim-safe Julia code.
