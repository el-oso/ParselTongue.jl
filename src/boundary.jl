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
    Mut{T}

Marker used in a `@pyfunc` signature to request an **in-place / mutable** argument:
`f!(x::Mut{Vector{Float64}})` receives a writable view over the Python buffer, so
mutations in Julia are written straight back to the caller's NumPy array. `@pyfunc`
peels `Mut{T}` to `T` for the actual function (the body uses `x` as a plain `T`);
the marker only affects how the buffer is acquired (writable vs read-only).
"""
struct Mut{T} end

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

# Complex scalars use an identity carrier: `Complex{T}` is an immutable `{T,T}`
# struct that maps directly to a C `{re; im;}` struct, passed/returned by value.
const COMPLEX_BOUNDARY_TYPES = (ComplexF32, ComplexF64)

for S in COMPLEX_BOUNDARY_TYPES
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

# `Nothing` is the void return carrier (for in-place `f!` functions).
c_abi_type(::Type{Nothing}) = Cvoid

c_abi_type(::Type{String}) = Cstring

from_c(::Type{String}, c::Cstring) = unsafe_string(c)

function to_c(s::String)::Cstring
    n = sizeof(s)
    p = Ptr{UInt8}(Libc.malloc(n + 1))
    GC.@preserve s unsafe_copyto!(p, pointer(s), n)
    unsafe_store!(p, 0x00, n + 1)   # NUL terminator
    return Cstring(p)
end

# ── Opaque handle types (@pyhandle) ───────────────────────────────────
# A handle is a Julia `struct` (immutable, isbitstype) stored on the C heap.
# The carrier `PtHandle` wraps a `void *` (the malloc'd pointer). On the Python
# side the wrapper is a `PyCapsule` whose destructor calls `free`.
#
# Lifecycle:
#   constructor @pyfunc → `to_c` mallocs + copies → C shim wraps in PyCapsule
#   method @pyfunc (arg) → C shim extracts pointer → `from_c` loads a copy
#   Python GC → PyCapsule destructor → `free`
#
# Mutation: handles are value types on the C heap, so "mutation" is functional —
# the method returns a new handle carrying the updated state.
#
# Restriction: `T` must satisfy `isbitstype(T)` (immutable struct, all-isbits
# fields). This guarantees safe `unsafe_store!`/`unsafe_load` on C-heap memory.

struct PtHandle
    ptr::Ptr{Cvoid}
end

"""
    @pyhandle T

Mark the immutable, isbits struct `T` as an opaque-handle boundary type.
After this annotation, `T` can be used as a `@pyfunc` argument or return type.
The Python side sees a `PyCapsule`; `free` is called automatically when the
capsule is garbage-collected.

`T` must satisfy `isbitstype(T)`.
"""
macro pyhandle(T_expr)
    T = Core.eval(__module__, T_expr)
    isbitstype(T) || error(
        "@pyhandle: `$T` must be an isbitstype (immutable struct with all-isbits fields).")
    quote
        ParselTongue.c_abi_type(::Type{$T}) = ParselTongue.PtHandle
        function ParselTongue.to_c(obj::$T)::ParselTongue.PtHandle
            p = Ptr{$T}(Libc.malloc(sizeof($T)))
            unsafe_store!(p, obj)
            ParselTongue.PtHandle(Ptr{Cvoid}(p))
        end
        function ParselTongue.from_c(::Type{$T}, h::ParselTongue.PtHandle)::$T
            unsafe_load(Ptr{$T}(h.ptr))
        end
        nothing
    end
end

# ── String-array boundary type ────────────────────────────────────────
# Carrier: `PtStrArray` (`{char **data; int64_t len;}`).
#   arg:  Python list[str] → C shim strdup's each item into `data`. Julia builds a
#         `Vector{String}` via `unsafe_string`. C shim frees after the call.
#   ret:  Julia mallocs each NUL-terminated string into `data`; C shim builds a
#         Python list and frees all pointers.

struct PtStrArray
    data::Ptr{Ptr{UInt8}}   # char ** (each NUL-terminated)
    len::Int64
end

c_abi_type(::Type{Vector{String}}) = PtStrArray

function from_c(::Type{Vector{String}}, c::PtStrArray)::Vector{String}
    n = Int(c.len)
    result = Vector{String}(undef, n)
    for i in 1:n
        result[i] = unsafe_string(unsafe_load(c.data, i))
    end
    return result
end

function to_c(v::Vector{String})::PtStrArray
    n = length(v)
    data = Ptr{Ptr{UInt8}}(Libc.malloc(max(1, n) * sizeof(Ptr{UInt8})))
    for i in 1:n
        s = v[i]
        sz = sizeof(s)
        q = Ptr{UInt8}(Libc.malloc(sz + 1))
        GC.@preserve s unsafe_copyto!(q, pointer(s), sz)
        unsafe_store!(q, 0x00, sz + 1)
        unsafe_store!(data, q, i)
    end
    return PtStrArray(data, Int64(n))
end

# ── N-D numeric array boundary type ───────────────────────────────────
# Carrier: a C-friendly `PtArray{T,N}` struct (data pointer + inline shape +
# contiguity flag). Input is zero-copy from any contiguous Python buffer; the
# *requested Julia type* selects the row/column-major policy:
#
#   ::Array{T,N}          dense Array, zero-copy. C-order input arrives transposed
#                         (reversed dims); F-order input is natural. (The C shim
#                         accepts either order.)
#   ::AbstractArray{T,N}  logical view (a PermutedDimsArray) whose shape and indices
#                         match NumPy, zero-copy. Requires C-contiguous input (the
#                         NumPy default; the shim enforces it) so the view type is
#                         fixed and the code stays trim-safe.
#
# Returns are always materialised dense and surface to NumPy in natural shape
# (the carrier is tagged column-major / `order='F'`). Julia mallocs, the shim frees.

"""
    PtArray{T,N}

C-ABI carrier for a contiguous N-D array: `data` pointer, inline `shape`, and an
`order` flag (0 = C-contiguous, 1 = F-contiguous/column-major). Layout matches the
C struct emitted into the extension shim.
"""
struct PtArray{T,N}
    data::Ptr{T}
    shape::NTuple{N,Int64}
    order::Cint
end

# Element types permitted in arrays (numpy-mappable numerics + complex).
const ARRAY_ELTYPES = (Int8, Int16, Int32, Int64, UInt8, UInt16, UInt32, UInt64,
                       Float32, Float64, ComplexF32, ComplexF64)
const PtArrayElt = Union{ARRAY_ELTYPES...}

# Both policies share the same carrier; `Array` is more specific than `AbstractArray`
# so a concrete `Matrix{T}` argument dispatches to the dense policy.
c_abi_type(::Type{Array{T,N}}) where {T<:PtArrayElt,N} = PtArray{T,N}
c_abi_type(::Type{<:AbstractArray{T,N}}) where {T<:PtArrayElt,N} = PtArray{T,N}

# Reverse a shape tuple trim-safely (N is a static type parameter).
_pt_revtuple(t::NTuple{N,Int64}) where {N} = ntuple(i -> @inbounds(t[N - i + 1]), Val(N))

# Dense policy: always an `Array{T,N}` (type-stable). C-order → reversed dims.
function from_c(::Type{Array{T,N}}, c::PtArray{T,N}) where {T<:PtArrayElt,N}
    dims = c.order == zero(Cint) ? _pt_revtuple(c.shape) : c.shape
    return unsafe_wrap(Array, c.data, dims)
end

# Logical policy: NumPy-shape view over the C-contiguous buffer (shim guarantees
# C-order). `_pt_logical` keeps the result a single concrete type per rank.
function from_c(::Type{S}, c::PtArray{T,N}) where {T<:PtArrayElt, N, S<:AbstractArray{T,N}}
    A = unsafe_wrap(Array, c.data, _pt_revtuple(c.shape))   # column-major alias of the buffer
    return _pt_logical(A, Val(N))
end
_pt_logical(A::Array{T,1}, ::Val{1}) where {T} = A
_pt_logical(A::Array{T,N}, ::Val{N}) where {T,N} =
    PermutedDimsArray(A, ntuple(i -> N - i + 1, Val(N)))

# Returns: dense column-major copy in natural shape; the shim builds a NumPy array
# with `order='F'` so it sees the same shape and values.
function to_c(A::AbstractArray{T,N}) where {T<:PtArrayElt,N}
    B = convert(Array{T,N}, A)
    n = length(B)
    p = Ptr{T}(Libc.malloc(max(n, 1) * sizeof(T)))
    GC.@preserve B unsafe_copyto!(p, pointer(B), n)
    return PtArray{T,N}(p, size(B), one(Cint))
end

# ── Optional (Union{T,Nothing}) boundary type ────────────────────────
# Carrier: PtOpt{C} where C = c_abi_type(inner T).
# Supported for scalar and String T only (not arrays, handles, or tuples).
# Only the C shim side calls into Python; from_c/to_c run inside the trimmed lib.

"""
    PtOpt{C}

C-ABI carrier for `Union{T,Nothing}`: `has_value=1` plus the inner carrier `C`,
or `has_value=0` (nothing). Maps to a C struct `{int32_t has_value; <C> value;}`.
"""
struct PtOpt{C}
    has_value::Int32
    value::C
end

_is_optional(@nospecialize(T::Type)) = T isa Union && (T.a === Nothing || T.b === Nothing)
_opt_inner(@nospecialize(T::Type))   = T.a === Nothing ? T.b : T.a

# Predicate on the carrier (as used in ccallable_gen.jl and cshim.jl).
isopt(@nospecialize(C::Type)) = C isa DataType && C.name === PtOpt.body.name
_opt_inner_c(@nospecialize(C::Type)) = C.parameters[1]  # inner carrier from PtOpt{C}

# c_abi_type for Optional — catch-all that only matches Union types.
# Specific methods (scalars, String, Array, …) take precedence due to Julia dispatch.
function c_abi_type(T::Type)
    _is_optional(T) || error("ParselTongue: c_abi_type not defined for type `$T`")
    inner = _opt_inner(T)
    return PtOpt{c_abi_type(inner)}
end

# from_c for Optional: extract inner T or return nothing. Trim-safe because
# T and C are static type parameters and both branches are type-stable.
function from_c(::Type{Union{T,Nothing}}, opt::PtOpt{C}) where {T,C}
    opt.has_value == zero(Int32) ? nothing : from_c(T, opt.value)
end

# _to_c_opt: used by emit_ccallable for Optional returns. Takes the carrier
# type explicitly so the nothing branch can zero-fill the value field.
function _to_c_opt(::Type{PtOpt{C}}, x::Union{T,Nothing}) where {C,T}
    x === nothing ? PtOpt{C}(zero(Int32), zero(C)) :
                    PtOpt{C}(one(Int32),  to_c(x)::C)
end

# ── Tuple return type ─────────────────────────────────────────────────
# A function may return a Tuple of boundary types -> a Python tuple. The carrier
# is a Julia Tuple of the element carriers (an immutable struct returned by value,
# matching a C struct of the element fields in order). Supported for RETURNS.

c_abi_type(::Type{T}) where {T<:Tuple} = Tuple{map(c_abi_type, fieldtypes(T))...}

to_c(t::Tuple) = map(to_c, t)   # element-wise; trim-safe (tuple map is unrolled)

# ── NamedTuple return type ─────────────────────────────────────────────
# A function may return a NamedTuple -> a Python dict{str, Any}. The carrier is
# the same as the underlying Tuple carrier (same C struct layout, same @ccallable
# return type). The C shim distinguishes by the original return type in PtExport
# and emits PyDict_New/PyDict_SetItemString instead of PyTuple_Pack.
# Supported for RETURNS only (not args — dict args require C-side key lookup by name).

c_abi_type(::Type{T}) where {T<:NamedTuple} = c_abi_type(Tuple{fieldtypes(T)...})

to_c(nt::NamedTuple) = map(to_c, Tuple(nt))  # trim-safe: concrete tuple map is unrolled

# ── Boundary validation (build host) ──────────────────────────────────

# Which of the three protocol methods are missing for `T`. Order-independent;
# computes the carrier type only once `c_abi_type` is known to exist.
function _missing_boundary_methods(T::Type)
    # Optional delegates validity to the inner type.
    _is_optional(T) && return _missing_boundary_methods(_opt_inner(T))
    missing = String[]
    # Use try/call rather than hasmethod: the catch-all c_abi_type(T::Type) makes
    # hasmethod return true for any type, including unsupported ones like Dict.
    has_cabi = false
    local C
    try
        C = c_abi_type(T)
        has_cabi = true
    catch
    end
    has_cabi || push!(missing, "c_abi_type(::Type{$T})")
    hasmethod(to_c, Tuple{T}) || push!(missing, "to_c(::$T)")
    if has_cabi
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
        "Built-in boundary types: scalars ($(join(SCALAR_BOUNDARY_TYPES, ", "))), " *
        "String, Vector{String}, Vector{<numeric>}, AbstractArray{<numeric>,N}, " *
        "Tuple/NamedTuple of the above, and @pyhandle isbitstype structs.\n" *
        "To add support for `$T`: define `c_abi_type`, `from_c`, and `to_c`."
    )
    return c_abi_type(T)
end

"""
    assert_ret_boundary(T::Type) -> Type

Validate a **return** type. Returns need only `c_abi_type` + `to_c` (not `from_c`);
`Nothing` (void) and `Tuple{…}` of boundary types are additionally allowed.
"""
function assert_ret_boundary(T::Type)
    T === Nothing && return Cvoid
    if _is_optional(T)
        inner = _opt_inner(T)
        isempty(_missing_boundary_methods(inner)) || error(
            "ParselTongue: Optional return type `$T` — inner type `$inner` is not a boundary type.")
        return c_abi_type(T)
    end
    if T <: NamedTuple
        for S in fieldtypes(T)
            assert_ret_boundary(S)
        end
        return c_abi_type(T)
    end
    if T <: Tuple
        for S in fieldtypes(T)
            assert_ret_boundary(S)
        end
        return c_abi_type(T)
    end
    (hasmethod(c_abi_type, Tuple{Type{T}}) && hasmethod(to_c, Tuple{T})) || error(
        "ParselTongue: return type `$T` cannot cross the Python boundary " *
        "(needs `c_abi_type(::Type{$T})` and `to_c(::$T)`)."
    )
    return c_abi_type(T)
end
