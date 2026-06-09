# Boundary Types

Because `juliac --trim` exposes only C-ABI functions, every argument and return
value of an exported function must be a **boundary type** — a Julia type that
ParselTongue knows how to lower to a C carrier and marshal to/from Python.

## Supported types (v1)

| Julia type | Python | C carrier | Notes |
|------------|--------|-----------|-------|
| `Int8`–`Int64`, `UInt8`–`UInt64` | `int` | same integer | |
| `Bool` | `bool` | `bool` | |
| `Float32`, `Float64` | `float` | `float`/`double` | |
| `String` | `str` | `Cstring` | UTF-8; see ownership below |
| `Vector{T}` (numeric `T`) | buffer ⇄ `numpy.ndarray` | `PtBuffer{T}` | zero-copy in; see [Arrays](/examples/arrays) |

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
  for the call). A returned `Vector` is copied into a Python-owned object. See
  [Arrays & NumPy](/examples/arrays).

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
