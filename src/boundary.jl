# ── Boundary type system ──────────────────────────────────────────────
#
# Every type that crosses the Julia <-> Python boundary is lowered to a
# C-ABI "carrier" type that `Base.@ccallable` accepts (scalars, `Cstring`,
# `Ptr{…}`, or C-friendly structs). Three operations define a boundary type:
#
#   c_abi_type(::Type{T}) -> Type      the carrier type T lowers to
#   from_c(::Type{T}, c)  -> T         carrier -> native   (runs INSIDE the lib)
#   to_c(x::T)            -> carrier    native  -> carrier  (runs INSIDE the lib)
#
# `from_c`/`to_c` are compiled into the trimmed library, so they must be
# trim-safe (type-stable, no dynamic dispatch). `c_abi_type` runs only on the
# build host during codegen.
#
# We model the protocol as a TypeContracts `@contract` so a missing impl is
# reported at build time with a clear message (via `satisfies`) instead of as a
# cryptic `juliac --trim` failure. The contract DSL can only substitute `Self`
# for a *bare* `::Self` argument (not one nested inside `::Type{Self}`), so the
# contract carries the one cleanly Self-anchored method, `to_c(::Self)`, as the
# boundary marker. The two methods whose signatures mention the *computed*
# carrier type — `c_abi_type(::Type{T})` and `from_c(::Type{T}, ::carrier)` — are
# verified explicitly in `is_boundary_type` / `assert_boundary`.

"""
    PyBoundary

Abstract marker for the Julia <-> Python boundary contract. Concrete types are
*not* required to subtype it — `satisfies(T, PyBoundary)` checks method existence
structurally (see TypeContracts). Register a type by defining `c_abi_type`,
`from_c`, and `to_c` for it.
"""
abstract type PyBoundary end

"""
    c_abi_type(::Type{T}) -> Type

The C-ABI carrier type that `T` is lowered to at the `@ccallable` boundary.
Evaluated on the build host during codegen (not inside the trimmed library).
"""
function c_abi_type end

"""
    from_c(::Type{T}, cval) -> T

Convert an incoming C-ABI value `cval` (of type `c_abi_type(T)`) into native
Julia `T`. Compiled into the trimmed library — must be trim-safe.
"""
function from_c end

"""
    to_c(x::T) -> c_abi_type(T)

Convert a native Julia value into its C-ABI carrier for return to Python.
Compiled into the trimmed library — must be trim-safe.
"""
function to_c end

@contract PyBoundary begin
    to_c(::Self)
end

# ── v1 scalar boundary types ──────────────────────────────────────────
# Scalars are their own C carrier: conversions are the identity.

const SCALAR_BOUNDARY_TYPES = (
    Int8, Int16, Int32, Int64,
    UInt8, UInt16, UInt32, UInt64,
    Float32, Float64, Bool,
)

for S in SCALAR_BOUNDARY_TYPES
    @eval c_abi_type(::Type{$S}) = $S
    @eval from_c(::Type{$S}, x::$S) = x
    @eval to_c(x::$S) = x
end

# ── String boundary type ──────────────────────────────────────────────
# Carrier: `Cstring` (a C `char*`).
#   arg:  Python `str` -> PyArg "s" -> borrowed `char*` -> copied into a Julia
#         String by `unsafe_string` (input buffer owned by Python, valid for the call).
#   ret:  Julia String -> a freshly `malloc`'d, NUL-terminated copy (the C shim
#         builds a Python str from it and `free`s it — ownership: Julia mallocs,
#         C frees). This avoids any dependence on Julia GC timing across the call.

c_abi_type(::Type{String}) = Cstring

from_c(::Type{String}, c::Cstring) = unsafe_string(c)

function to_c(s::String)::Cstring
    n = sizeof(s)
    p = Ptr{UInt8}(Libc.malloc(n + 1))
    GC.@preserve s unsafe_copyto!(p, pointer(s), n)
    unsafe_store!(p, 0x00, n + 1)   # NUL terminator
    return Cstring(p)
end

# ── 1-D numeric array boundary type ───────────────────────────────────
# Carrier: a C-friendly `PtBuffer{T}` struct (data pointer + element count).
#   arg:  any Python object exporting the buffer protocol (numpy array,
#         array.array, memoryview) -> data pointer + length -> a zero-copy
#         `unsafe_wrap`'d Julia view (input memory owned by Python, valid for the call).
#   ret:  Julia Vector -> a freshly `malloc`'d copy in the carrier; the C shim
#         copies it into a Python object (numpy array when available, else
#         memoryview) and frees it. Same Julia-mallocs / C-frees ownership as strings.

"""
    PtBuffer{T}

C-ABI carrier for a contiguous 1-D numeric array: a `data` pointer and an element
count `len`. Layout matches the C struct emitted into the extension shim.
"""
struct PtBuffer{T}
    data::Ptr{T}
    len::Int64
end

# Element types permitted in arrays (numpy-mappable numerics).
const ARRAY_ELTYPES = (Int8, Int16, Int32, Int64, UInt8, UInt16, UInt32, UInt64, Float32, Float64)
const PtArrayElt = Union{ARRAY_ELTYPES...}

c_abi_type(::Type{Vector{T}}) where {T<:PtArrayElt} = PtBuffer{T}

from_c(::Type{Vector{T}}, b::PtBuffer{T}) where {T<:PtArrayElt} =
    unsafe_wrap(Array, b.data, (Int(b.len),))   # zero-copy view of Python's buffer

function to_c(v::Vector{T}) where {T<:PtArrayElt}
    n = length(v)
    p = Ptr{T}(Libc.malloc(max(n, 1) * sizeof(T)))
    GC.@preserve v unsafe_copyto!(p, pointer(v), n)
    return PtBuffer{T}(p, n)
end

# ── Boundary validation (build host) ──────────────────────────────────

# Which of the three protocol methods are missing for `T`. Order-independent;
# computes the carrier type only once `c_abi_type` is known to exist.
function _missing_boundary_methods(T::Type)
    missing = String[]
    has_cabi = hasmethod(c_abi_type, Tuple{Type{T}})
    has_cabi || push!(missing, "c_abi_type(::Type{$T})")
    hasmethod(to_c, Tuple{T}) || push!(missing, "to_c(::$T)")
    if has_cabi
        C = c_abi_type(T)
        hasmethod(from_c, Tuple{Type{T}, C}) || push!(missing, "from_c(::Type{$T}, ::$C)")
    else
        push!(missing, "from_c(::Type{$T}, ::<carrier>)")
    end
    return missing
end

"""
    is_boundary_type(T::Type) -> Bool

True when `T` implements the full boundary protocol (`c_abi_type`, `to_c`,
`from_c`). Non-throwing form of `assert_boundary`.
"""
is_boundary_type(T::Type) = isempty(_missing_boundary_methods(T))

"""
    assert_boundary(T::Type) -> Type

Verify that `T` is a registered boundary type and return its C-ABI carrier type.
Throws a descriptive error (not a trim failure) when `T` cannot cross the boundary.
"""
function assert_boundary(T::Type)
    missing = _missing_boundary_methods(T)
    isempty(missing) || error(
        "ParselTongue: type `$T` cannot cross the Python boundary.\n" *
        "Missing boundary methods: $(join(missing, ", ")).\n" *
        "Supported in v1: $(join(SCALAR_BOUNDARY_TYPES, ", ")), and (later) String / numeric arrays.\n" *
        "Define `c_abi_type`, `from_c`, and `to_c` for `$T` to add support."
    )
    return c_abi_type(T)
end
