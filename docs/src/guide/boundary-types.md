# Boundary Types

Because `juliac --trim` exposes only C-ABI functions, every argument and return
value of an exported function must be a **boundary type** — a Julia type that
ParselTongue knows how to lower to a C carrier and marshal to/from Python.

## Supported types

| Julia type | Python | Notes |
|------------|--------|-------|
| `Int8`–`Int64`, `UInt8`–`UInt64` | `int` | |
| `Bool` | `bool` | |
| `Float32`, `Float64` | `float` | |
| `ComplexF32`, `ComplexF64` | `complex` | scalars and array elements |
| `String` | `str` | UTF-8; see ownership below |
| `Array{T,N}` / `AbstractArray{T,N}` (numeric/complex `T`) | `numpy.ndarray` (buffer in) | zero-copy; the *type* picks the memory-order policy — see [Arrays & NumPy](/examples/arrays) |
| `Mut{T}` (argument only) | writable buffer | in-place mutation writes back to NumPy — see [In-place](#In-place-mutation-and-void-returns) |
| `Nothing` (return only) | `None` | for `f!`-style in-place functions |
| `Tuple{…}` (return only) | `tuple` | multiple return values, e.g. `(q, r)` |

`@pymodule pkg.sub begin … end` groups functions into a Python **submodule**
(`pkg.sub`) over one compiled extension — see [Submodules](/examples/scientific#Submodules).

A signature that uses anything else is rejected **at build time** with a clear
message — not a cryptic trim error:

```julia
@pyfunc bad(d::Dict{String,Int})::Int = length(d)
# ERROR: ParselTongue: type `Dict{String, Int64}` cannot cross the Python boundary.
# Missing boundary methods: c_abi_type(::Type{...}), to_c(::...), from_c(...).
```

This check is a [TypeContracts.jl](https://github.com/el_oso/TypeContracts.jl)
contract ([`PyBoundary`](@ref)): the boundary protocol is registered as an
interface and verified with `satisfies` before any compilation happens.

## Ownership and copies

- **Strings.** A `str` argument is borrowed for the duration of the call and
  copied into a Julia `String`. A returned `String` is copied into a freshly
  `malloc`'d C buffer; the shim builds a Python `str` from it and frees it
  (Julia allocates, C frees) — no dependence on Julia GC timing.
- **Arrays.** An array argument is a zero-copy view over the Python buffer (valid
  for the call). A returned array is copied into a Python-owned object in natural
  shape. See [Arrays & NumPy](/examples/arrays).

## N-D arrays: the dual policy

NumPy is row-major (C order); Julia is column-major. Rather than transpose
silently, the **argument type** you write selects the zero-copy policy:

- `::AbstractArray{T,N}` (e.g. `AbstractMatrix{Float64}`) → a **logical view**
  with NumPy's shape and indexing (`A[i,j]` matches `a[i,j]`). Ideal for
  elementwise / indexing code. Requires C-contiguous input (the NumPy default).
- `::Array{T,N}` (e.g. `Matrix{Float64}`) → a dense `Array`, never copied for
  BLAS — but a C-order input arrives **transposed** (axes reversed). Pass
  `np.asfortranarray(x)` to get the natural shape, or do the transpose bookkeeping
  yourself.

Returns always surface to NumPy in natural shape. Full worked example:
[Arrays & NumPy](/examples/arrays).

## In-place mutation and void returns

Wrap an array argument in `Mut{…}` to receive a **writable** view, so Julia
mutations write straight back to the caller's NumPy array (no copy). Pair it with
a `::Nothing` return for the idiomatic `f!` pattern:

```julia
@pyfunc scale!(x::Mut{Vector{Float64}}, k::Float64)::Nothing = (x .*= k; nothing)
```

```python
>>> x = np.array([1.0, 2.0, 3.0]); mymod.scale(x, 10.0); x
array([10., 20., 30.])
```

`Mut{T}` is peeled to `T` for the Julia function (the body uses a plain array);
it only affects how the buffer is acquired. A trailing `!` in the Julia name is
dropped for the Python name (`scale!` → `scale`).

## Extending the boundary

The boundary protocol is three functions ([`c_abi_type`](@ref), [`from_c`](@ref),
[`to_c`](@ref)). The `from_c`/`to_c` conversions run **inside** the trimmed
library, so they must be trim-safe (type-stable, no dynamic dispatch). A custom
boundary type looks like the built-in scalar definitions:

```julia
ParselTongue.c_abi_type(::Type{MyInt}) = Int64
ParselTongue.from_c(::Type{MyInt}, x::Int64) = MyInt(x)
ParselTongue.to_c(x::MyInt) = Int64(x.value)
```

After defining all three, `ParselTongue.is_boundary_type(MyInt)` returns `true`
and `MyInt` may appear in `@pyfunc` signatures.

See the [API Reference](/reference/api#Boundary-type-system) for the full
docstrings of [`PyBoundary`](@ref), [`c_abi_type`](@ref), [`from_c`](@ref), and
[`to_c`](@ref).
