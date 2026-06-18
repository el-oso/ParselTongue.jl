# Callbacks & Errors

Two features that make a module feel native to Python: accepting **Python callables**
as arguments, and raising **typed Python exceptions**. Everything below is one file,
`numkit.jl`, and every block is checked in CI.

## The module

Register the custom exception types first (so they exist when the module is built),
then declare the functions. Callbacks are typed with `PyCallable{Args, Ret}`; the
bare `PyCallable` is shorthand for `Float64 → Float64`:

```julia
# numkit.jl
using ParselTongue

# Map Julia exception types onto Python exception classes (default base Exception).
@pyerror DomainError                 # → numkit.DomainError   <: Exception
@pyerror ArgumentError <: ValueError # → numkit.ArgumentError <: ValueError

@pymodule numkit begin
    # ── Python callables as arguments ───────────────────────────────────────
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

    # Other signatures: (Int64, Int64) -> Int64, plus String and Vector.
    @pyfunc combine(f::PyCallable{Tuple{Int64,Int64},Int64}, a::Int64, b::Int64)::Int64 = f(a, b)
    @pyfunc apply_str(f::PyCallable{Tuple{String},String}, s::String)::String = f(s)
    @pyfunc apply_vec(f::PyCallable{Tuple{Vector{Float64}},Vector{Float64}},
                      v::Vector{Float64})::Vector{Float64} = f(v)

    # ── Errors ──────────────────────────────────────────────────────────────
    # A plain error(...) surfaces in Python as RuntimeError.
    @pyfunc checked_inv(x::Float64)::Float64 =
        x == 0.0 ? error("cannot invert zero") : 1.0 / x

    # throw a registered type → the matching Python exception class.
    @pyfunc sqrt_checked(x::Float64)::Float64 =
        x < 0.0 ? throw(DomainError(x, "negative input")) : sqrt(x)

    @pyfunc nth_root(x::Float64, n::Int64)::Float64 =
        n <= 0 ? throw(ArgumentError("n must be positive")) : x^(1.0 / n)
end
```

## Calling back into Python

You pass any callable — a `lambda`, a `def`, or a builtin — and it is invoked back
inside the Julia function:

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
>>> import array
>>> [float(x) for x in numkit.apply_vec(sorted, array.array("d", [3.0, 1.0, 2.0]))]
[1.0, 2.0, 3.0]
```

(`apply_vec`'s `v::Vector{Float64}` argument arrives over the buffer protocol, so
pass an `array.array` or a numpy array — not a plain `list`. The return is a numpy
array when numpy is installed, otherwise a `memoryview`; iterating with `float(x)`
displays it uniformly.)

Supported callback argument/return types are scalars, `String` (↔ `str`), and
`Vector{T}` for scalar `T` (↔ `list`). Each call re-acquires the GIL, boxes the
arguments, invokes the callable, and unwraps the result — releasing the GIL and
every temporary reference on all paths (see the
[GIL discussion](/guide/vs-pyo3#GIL-management)).

## Raising Python exceptions

A plain `error(...)` becomes a `RuntimeError`:

```python
>>> numkit.checked_inv(2.0)
0.5
>>> numkit.checked_inv(0.0)
Traceback (most recent call last):
    ...
RuntimeError: cannot invert zero
```

The types registered with `@pyerror` become real classes on the module, so Python
can catch them precisely **by class** — and `ArgumentError`, declared
`<: ValueError`, is caught by `except ValueError` too:

```python
>>> try:
...     numkit.sqrt_checked(-1.0)
... except numkit.DomainError:
...     print("caught DomainError")
caught DomainError
>>> try:
...     numkit.nth_root(8.0, 0)
... except ValueError:                    # ArgumentError <: ValueError
...     print("caught ValueError")
caught ValueError
>>> round(numkit.nth_root(8.0, 3), 6)
2.0
```

The error code is packed into an out-parameter and decoded by the generated C
shim into the right `PyErr_SetString` call — no dynamic Python-object creation
happens inside the trim-safe Julia code.

!!! note "Exception messages"
    A plain `error("…")` throws Julia's `ErrorException`, whose message is forwarded
    verbatim (the `RuntimeError: cannot invert zero` above). A typed `@pyerror`
    exception carries the right Python **class**, but its message currently surfaces
    generically — match on the class, as shown, rather than on the message text.

## Build it

```julia
using ParselTongue
build_wheel("numkit.jl")
```
