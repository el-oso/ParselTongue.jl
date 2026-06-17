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

from_c(::Type{String}, c::Cstring) = (@assert c != C_NULL; unsafe_string(c))

function to_c(s::String)::Cstring
    n = sizeof(s)
    p = Ptr{UInt8}(Libc.malloc(n + 1))
    @assert p != C_NULL
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

"""
    PtHandle{T}

C-ABI carrier for opaque-handle boundary types registered with `@pyhandle`.
Wraps a `void *` pointing to a heap-allocated copy of the Julia struct. On the Python
side the handle appears as an instance of a proper Python class (`mod.T`); the C heap
memory is freed automatically when the Python object is garbage-collected.
"""
struct PtHandle{T}
    ptr::Ptr{Cvoid}
end

# Build-host registry for @pyhandle types, in registration order.
const _HANDLE_TYPES = Type[]

"""
    @pyhandle T

Mark the immutable, isbits struct `T` as an opaque-handle boundary type.
After this annotation, `T` can be used as a `@pyfunc` argument or return type.
On the Python side `T` appears as a real Python class (`mod.T`); `isinstance`
checks, `repr`, and tab-completion all work. The C heap allocation is freed
automatically when the Python object is garbage-collected.

`T` must satisfy `isbitstype(T)`.
"""
macro pyhandle(T_expr, opts...)
    mutable, subclass, dict = _parse_class_opts(:pyhandle, opts)
    T = Core.eval(__module__, T_expr)
    isbitstype(T) || error(
        "@pyhandle: `$T` must be an isbitstype (immutable struct with all-isbits fields).")
    T in _HANDLE_TYPES || push!(_HANDLE_TYPES, T)
    mutable  && (T in _MUTABLE_HANDLE_TYPES || push!(_MUTABLE_HANDLE_TYPES, T))
    subclass && (T in _SUBCLASS_TYPES || push!(_SUBCLASS_TYPES, T))
    dict     && (T in _DICT_TYPES || push!(_DICT_TYPES, T))

    quote
        ParselTongue.c_abi_type(::Type{$T}) = ParselTongue.PtHandle{$T}
        function ParselTongue.to_c(obj::$T)::ParselTongue.PtHandle{$T}
            p = Ptr{$T}(Libc.malloc(sizeof($T)))
            @assert p != C_NULL
            unsafe_store!(p, obj)
            ParselTongue.PtHandle{$T}(Ptr{Cvoid}(p))
        end
        function ParselTongue.from_c(::Type{$T}, h::ParselTongue.PtHandle{$T})::$T
            unsafe_load(Ptr{$T}(h.ptr))
        end
        # Trim-safety scan for to_c/from_c. check_trim_compat walks the supertype
        # chain of T looking for @contract specs — for user structs that don't subtype
        # PyBoundary this is a no-op today. TypeContracts would need a structural form
        # (@verify T for_contract=PyBoundary trim_compat=true) to cover this case.
        TypeContracts.check_trim_compat($T)
        # Runtime re-registration (survives clear_exports! between macro expansion and read).
        $(_class_opt_push_expr(T, mutable, :_MUTABLE_HANDLE_TYPES))
        $(_class_opt_push_expr(T, subclass, :_SUBCLASS_TYPES))
        $(_class_opt_push_expr(T, dict, :_DICT_TYPES))
        nothing
    end
end

# Parse `mutable=`/`subclass=`/`dict=` boolean opts shared by @pyhandle / @pymutable.
# `subclass`/`dict` mirror PyO3 #[pyclass(subclass)] / #[pyclass(dict)] (default off).
function _parse_class_opts(macroname::Symbol, opts)
    mutable = false; subclass = false; dict = false
    for opt in opts
        (opt isa Expr && opt.head === :(=)) ||
            error("@$macroname: options must be `name=true/false`, got `$opt`.")
        k = opt.args[1]
        v = opt.args[2] === true || (opt.args[2] isa Bool && opt.args[2])
        if     k === :mutable;  mutable  = v
        elseif k === :subclass; subclass = v
        elseif k === :dict;     dict     = v
        else error("@$macroname: unknown option `$k` (expected mutable/subclass/dict).")
        end
    end
    return (mutable, subclass, dict)
end

# Runtime push into a registry (no-op when the flag is off).
_class_opt_push_expr(T, flag::Bool, reg::Symbol) =
    flag ? :( $T in getfield(ParselTongue, $(QuoteNode(reg))) ||
              push!(getfield(ParselTongue, $(QuoteNode(reg))), $T) ) : :(nothing)

"""
    @pymutable T

Register a `mutable struct` `T` as a **real, mutable Python class**. Unlike
[`@pyhandle`](@ref) (which requires an `isbitstype` and treats handles as immutable
value types), `@pymutable` supports arbitrary field types — including `String`,
`Vector`, and nested structs — and lets `@pymethod`s mutate the object in place.

The mechanism is a per-type Julia GC registry: each instance is stored in a
`Dict{Int64, T}` keyed by a monotically increasing id. The Python object holds only
the id; `from_c` returns the *live Julia object* (not a copy), so field assignments
inside a `@pymethod` persist. When Python garbage-collects the object, `tp_dealloc`
removes it from the registry, releasing the Julia reference.

```julia
mutable struct Counter
    count::Int64
    name::String
end
@pymutable Counter

@pymethod __new__ counter_new(name::String)::Counter = Counter(0, name)
@pymethod increment! incr(c::Counter)::Int64 = (c.count += 1; c.count)
```

Scalar and `String` fields are exposed as read/write Python attributes. Because the
registry is a concretely-typed global, all of `to_c`/`from_c`/dealloc remain
trim-safe. `@pymutable` is the recommended base for stateful iterators
(`@pymethod __next__`).
"""
macro pymutable(T_expr, opts...)
    _, subclass, dict = _parse_class_opts(:pymutable, opts)
    T = Core.eval(__module__, T_expr)
    (T isa DataType && Base.ismutabletype(T)) || error(
        "@pymutable: `$T` must be a `mutable struct` (got an immutable or non-struct type). " *
        "Use @pyhandle for immutable isbits structs.")
    subclass && (T in _SUBCLASS_TYPES || push!(_SUBCLASS_TYPES, T))
    dict     && (T in _DICT_TYPES || push!(_DICT_TYPES, T))
    tname   = string(T.name.name)
    reg_sym = esc(Symbol("_PtRegistry_", tname))
    seq_sym = esc(Symbol("_PtIdSeq_", tname))
    Tq      = esc(T_expr)
    quote
        # Per-type GC registry: a concretely-typed Dict keeps registered objects
        # alive (it is a GC root) and all operations dispatch on concrete types,
        # so to_c/from_c stay trim-safe inside the trimmed library.
        const $reg_sym = Base.Dict{Int64, $Tq}()
        const $seq_sym = Base.Ref{Int64}(0)
        ParselTongue.c_abi_type(::Type{$Tq}) = ParselTongue.PtHandle{$Tq}
        # to_c: register and pack the id into the handle's pointer slot.
        function ParselTongue.to_c(obj::$Tq)::ParselTongue.PtHandle{$Tq}
            local _id::Int64 = $seq_sym[] + Int64(1)
            $seq_sym[] = _id
            $reg_sym[_id] = obj
            ParselTongue.PtHandle{$Tq}(Ptr{Cvoid}(_id))
        end
        # from_c: return the LIVE object (mutations persist), not a copy.
        function ParselTongue.from_c(::Type{$Tq}, h::ParselTongue.PtHandle{$Tq})::$Tq
            $reg_sym[Int64(h.ptr)]
        end
        # Dealloc entry point: drop the registry reference so Julia can collect it.
        Base.@ccallable function $(esc(Symbol("_pt_dealloc_", tname, "_jl")))(h::ParselTongue.PtHandle{$Tq})::Cvoid
            Base.delete!($reg_sym, Int64(h.ptr))
            return nothing
        end
        TypeContracts.check_trim_compat($Tq)
        # Runtime registration (survives clear_exports! between macro expansion and
        # the point where the registries are read).
        $Tq in ParselTongue._MUTABLE_STRUCT_TYPES ||
            push!(ParselTongue._MUTABLE_STRUCT_TYPES, $Tq)
        $Tq in ParselTongue._HANDLE_TYPES ||
            push!(ParselTongue._HANDLE_TYPES, $Tq)
        $(_class_opt_push_expr(T, subclass, :_SUBCLASS_TYPES))
        $(_class_opt_push_expr(T, dict, :_DICT_TYPES))
        nothing
    end
end

"""
    @boundary T carrier=C begin
        from_c(c) = ...
        to_c(x) = ...
    end

Register a user-defined type `T` as a boundary type with carrier `C` (an
existing boundary carrier, e.g. `PtArray{Float64,1}`, `Cstring`, a scalar).

The `begin...end` block must contain:
- `from_c(c) = ...` — converts an incoming carrier `c::C` to a value of type `T`.
  Runs inside the trimmed library → **must be trim-safe** (type-stable, no dynamic
  dispatch).
- `to_c(x) = ...` — converts a value `x::T` to carrier `C`. Also trim-safe.

Validates the protocol immediately: errors at `@boundary` time rather than
deep in a juliac build if the implementation is missing or wrong.

The carrier `C` must be marshallable by the C shim: scalars, `Cstring`,
`PtArray{T,N}`, `PtStrArray`, `PtHandle`, `PtOpt{C}`, or `PtDict{V}`.
User types may share a carrier — each gets its own `from_c`/`to_c` dispatch.

## Example

```julia
struct Point2D; x::Float64; y::Float64; end

@boundary Point2D carrier=PtArray{Float64,1} begin
    from_c(c) = Point2D(unsafe_load(c.data, 1), unsafe_load(c.data, 2))
    to_c(p) = ParselTongue.to_c([p.x, p.y])
end

@pyfunc scale(pt::Point2D, s::Float64)::Point2D = Point2D(pt.x*s, pt.y*s)
```

Python callers pass/receive a 2-element 1-D float64 numpy array.
"""
macro boundary(T_expr, carrier_eq, block)
    (carrier_eq isa Expr && carrier_eq.head === :(=) &&
     carrier_eq.args[1] isa Symbol && carrier_eq.args[1] === :carrier) ||
        error("@boundary: second argument must be `carrier=C`, got: $carrier_eq")
    C_expr = carrier_eq.args[2]

    (block isa Expr && block.head === :block) ||
        error("@boundary: third argument must be a `begin...end` block")

    # Locate from_c and to_c definitions in the block.
    from_c_def = nothing
    to_c_def = nothing
    for stmt in block.args
        stmt isa LineNumberNode && continue
        if stmt isa Expr && stmt.head in (:function, :(=)) && length(stmt.args) >= 2
            sig = stmt.args[1]
            if sig isa Expr && sig.head === :call
                fname = sig.args[1]
                if fname === :from_c; from_c_def = stmt
                elseif fname === :to_c; to_c_def = stmt
                end
            end
        end
    end
    from_c_def !== nothing || error("@boundary: `from_c(c) = ...` missing from block")
    to_c_def   !== nothing || error("@boundary: `to_c(x) = ...` missing from block")

    # Validate arg count and extract arg names (stripping any user type annotation).
    fc_sig = from_c_def.args[1]; tc_sig = to_c_def.args[1]
    length(fc_sig.args) == 2 || error("@boundary: from_c must have exactly one argument")
    length(tc_sig.args) == 2 || error("@boundary: to_c must have exactly one argument")
    _strip(a) = (a isa Expr && a.head === :(::)) ? a.args[1] : a
    fc_arg = _strip(fc_sig.args[2])
    tc_arg = _strip(tc_sig.args[2])
    fc_body = from_c_def.args[2]
    tc_body = to_c_def.args[2]

    quote
        ParselTongue.c_abi_type(::Type{$(esc(T_expr))}) = $(esc(C_expr))
        function ParselTongue.from_c(::Type{$(esc(T_expr))}, $(esc(fc_arg))::$(esc(C_expr)))
            $(esc(fc_body))
        end
        function ParselTongue.to_c($(esc(tc_arg))::$(esc(T_expr)))
            $(esc(tc_body))
        end
        let _t = $(esc(T_expr))
            _m = ParselTongue._missing_boundary_methods(_t)
            if !isempty(_m)
                error("@boundary: type `" * string(_t) *
                      "` failed protocol validation after registration. Missing: " *
                      join(_m, ", ") * ".")
            end
            # Trim-safety scan. Same structural gap as @pyhandle: a no-op for types
            # that don't subtype PyBoundary. TypeContracts needs structural trim
            # checking to cover user-registered boundary types.
            TypeContracts.check_trim_compat(_t)
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

# ── Dict{String,V} boundary type ─────────────────────────────────────
# Carrier: `PtDict{V}` — parallel key (char**) and value (V*) arrays plus a count.
# The C shim builds these arrays from the Python dict (strdup-ing each key), passes
# the struct to Julia, which iterates it to build a `Dict{String,V}` and then frees
# the C memory.  For returns, Julia builds the arrays via `to_c` and the C shim
# converts them to a PyDict (freeing the C arrays afterwards).
# Restricted to scalar V (not Complex, String, or Array) for v1.

"""
    PtDict{V}

C-ABI carrier for `Dict{String,V}`: parallel arrays of strdup'd key strings and
values plus a length. Both arrays are malloc'd by whichever side builds the struct
and freed by whichever side consumes it.
"""
struct PtDict{V}
    keys::Ptr{Ptr{UInt8}}   # char** (each NUL-terminated, malloc'd)
    vals::Ptr{V}            # V* (malloc'd)
    len::Int64
end

# Restrict to integer + float scalar types (not Bool/Complex for v1 to keep C
# value extraction simple — Bool needs PyObject_IsTrue, Complex needs special struct).
const _DICT_VAL_TYPES = (Int8, Int16, Int32, Int64, UInt8, UInt16, UInt32, UInt64,
                          Float32, Float64, Bool)

isdict(@nospecialize(C::Type)) = C isa DataType && C.name === PtDict.body.name
_dict_val_c(@nospecialize(C::Type)) = C.parameters[1]

for _V in _DICT_VAL_TYPES
    @eval c_abi_type(::Type{Dict{String,$_V}}) = PtDict{$_V}

    # from_c: iterate parallel arrays → Julia Dict, then free the C memory.
    # Trim-safe: all types are concrete; Dict{String,V} iteration is type-stable.
    @eval function from_c(::Type{Dict{String,$_V}}, c::PtDict{$_V})::Dict{String,$_V}
        n = Int(c.len)
        d = Dict{String,$_V}()
        for i in 1:n
            kptr = unsafe_load(c.keys, i)
            d[unsafe_string(kptr)] = unsafe_load(c.vals, i)
            Libc.free(kptr)
        end
        Libc.free(c.keys)
        Libc.free(c.vals)
        return d
    end

    # to_c: build parallel arrays from the Julia Dict (malloc'd; C shim frees them).
    @eval function to_c(d::Dict{String,$_V})::PtDict{$_V}
        n = length(d)
        kp = Ptr{Ptr{UInt8}}(Libc.malloc(max(1, n) * sizeof(Ptr{UInt8})))
        vp = Ptr{$_V}(Libc.malloc(max(1, n) * sizeof($_V)))
        i = 1
        for (k, v) in d
            sz = sizeof(k)
            q = Ptr{UInt8}(Libc.malloc(sz + 1))
            GC.@preserve k unsafe_copyto!(q, pointer(k), sz)
            unsafe_store!(q, 0x00, sz + 1)
            unsafe_store!(kp, q, i)
            unsafe_store!(vp, v, i)
            i += 1
        end
        return PtDict{$_V}(kp, vp, Int64(n))
    end
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
function _opt_inner(@nospecialize(T::Type))
    @assert !(T.a isa Union) && !(T.b isa Union) "ParselTongue: Union{A,B,Nothing} is not a supported Optional type"
    T.a === Nothing ? T.b : T.a
end

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

# ── Variadic args (PtVarArgs{T}) ─────────────────────────────────────
# Mark the last positional argument as variadic: Python callers pass any number
# of positional values beyond the fixed args; the C shim collects them into a
# malloc'd scalar array passed as a PtArray{T,1} carrier. Julia sees a
# PtVarArgs{T} <: AbstractVector{T}, zero-copy from the C buffer.
# Restriction: T must be a real numeric scalar (Int*/UInt*/Float*). Complex and
# Bool are excluded because they require non-trivial Python extraction.

"""
    PtVarArgs{T} <: AbstractVector{T}

Boundary type for variadic positional arguments. Mark the last positional argument
of a `@pyfunc` as `PtVarArgs{T}` to accept any number of extra Python positional
values. `T` must be a numeric scalar type (Int8–Int64, UInt8–UInt64, Float32,
Float64). Python callers pass values as ordinary positional arguments; Julia sees a
zero-copy `AbstractVector{T}`.
"""
struct PtVarArgs{T} <: AbstractVector{T}
    data::Vector{T}
end
Base.size(v::PtVarArgs{T}) where T = size(v.data)
Base.getindex(v::PtVarArgs{T}, i::Int) where T = v.data[i]

isvarargs(@nospecialize(T::Type)) = false
isvarargs(::Type{PtVarArgs{T}}) where T = true
_varargs_elt(::Type{PtVarArgs{T}}) where T = T

# Scalar element types for which PyArg_Parse has a simple one-char format code.
const _PtVarArgElt = Union{Int8, Int16, Int32, Int64,
                            UInt8, UInt16, UInt32, UInt64,
                            Float32, Float64}

function c_abi_type(::Type{PtVarArgs{T}}) where T
    T <: _PtVarArgElt || error(
        "ParselTongue: PtVarArgs element type must be a numeric scalar " *
        "(Int8/16/32/64, UInt8/16/32/64, Float32/Float64); got `$T`.")
    return PtArray{T,1}
end

function from_c(::Type{PtVarArgs{T}}, c::PtArray{T,1}) where {T<:_PtVarArgElt}
    PtVarArgs{T}(from_c(Vector{T}, c))
end

to_c(v::PtVarArgs{T}) where {T<:_PtVarArgElt} = to_c(v.data)

# ── PyCallable: Python callable objects ───────────────────────────────
#
# Carrier: Ptr{Cvoid} (a raw PyObject* cast to void*). The C shim extracts it
# with the "O" format, checks PyCallable_Check, Py_INCREFs it before the GIL
# is released, and Py_DECREFs it after the Julia call returns.
#
# Calling from Julia: the C shim releases the GIL before calling the Julia
# function. Use `f(x::Float64)::Float64` (or any supported overload) to call
# back into Python: it re-acquires the GIL via PyGILState_Ensure, builds a
# Python tuple, calls PyObject_Call, extracts the result, and releases the GIL.
# All of this is implemented as direct ccall invocations — no Julia method
# dispatch — so it is trim-safe under --trim=safe.

"""
    PyCallable{Args<:Tuple, Ret}
    PyCallable                      # alias for PyCallable{Tuple{Float64}, Float64}

Boundary type for a Python callable passed as a `@pyfunc` argument. The type
parameters declare the call signature: `Args` is a `Tuple` of argument types and
`Ret` the return type. Calling `f(a, b, …)::Ret` re-acquires the GIL, boxes each
argument, invokes `PyObject_Call`, and returns the unwrapped `Ret` result — all
via direct `ccall` invocations emitted by a `@generated` method, so it is
trim-safe under `--trim=safe`.

The bare name `PyCallable` (no parameters) defaults to `Float64 → Float64`:

```julia
@pyfunc apply(f::PyCallable, x::Float64)::Float64 = f(x)             # Float64→Float64
@pyfunc apply2(f::PyCallable{Tuple{Int64,Int64},Int64}, a::Int64, b::Int64)::Int64 = f(a, b)
```

Supported argument and return scalar types: `Int8`–`Int64`, `UInt8`–`UInt64`,
`Bool`, `Float32`, `Float64`.
"""
struct PyCallable{Args<:Tuple, Ret} <: PyBoundary
    ptr::Ptr{Cvoid}
end

# Carrier is always a raw PyObject* (void *), regardless of the declared signature.
c_abi_type(::Type{<:PyCallable}) = Ptr{Cvoid}
from_c(::Type{PyCallable{A,R}}, p::Ptr{Cvoid}) where {A,R} = PyCallable{A,R}(p)
# Bare `PyCallable` (UnionAll) defaults to the Float64 → Float64 signature.
from_c(::Type{PyCallable}, p::Ptr{Cvoid}) = PyCallable{Tuple{Float64},Float64}(p)
to_c(f::PyCallable) = f.ptr

# Verify the PyBoundary contract on a concrete PyCallable instantiation and confirm
# that to_c/from_c are trim-safe (no invokelatest, Base.which, etc.).
@verify PyCallable{Tuple{Float64},Float64} trim_compat=true

# ── Per-type scalar boxing / unboxing (trim-safe direct ccalls) ────────
# Each method is concretely typed, so dispatch from the @generated call operator
# resolves statically and compiles to a single ccall.
_py_box(x::Float64) = ccall(:PyFloat_FromDouble,         Ptr{Cvoid}, (Float64,),   x)
_py_box(x::Float32) = ccall(:PyFloat_FromDouble,         Ptr{Cvoid}, (Float64,),   Float64(x))
_py_box(x::Int8)    = ccall(:PyLong_FromLongLong,        Ptr{Cvoid}, (Clonglong,), Clonglong(x))
_py_box(x::Int16)   = ccall(:PyLong_FromLongLong,        Ptr{Cvoid}, (Clonglong,), Clonglong(x))
_py_box(x::Int32)   = ccall(:PyLong_FromLongLong,        Ptr{Cvoid}, (Clonglong,), Clonglong(x))
_py_box(x::Int64)   = ccall(:PyLong_FromLongLong,        Ptr{Cvoid}, (Clonglong,), x)
_py_box(x::UInt8)   = ccall(:PyLong_FromUnsignedLongLong,Ptr{Cvoid}, (Culonglong,),Culonglong(x))
_py_box(x::UInt16)  = ccall(:PyLong_FromUnsignedLongLong,Ptr{Cvoid}, (Culonglong,),Culonglong(x))
_py_box(x::UInt32)  = ccall(:PyLong_FromUnsignedLongLong,Ptr{Cvoid}, (Culonglong,),Culonglong(x))
_py_box(x::UInt64)  = ccall(:PyLong_FromUnsignedLongLong,Ptr{Cvoid}, (Culonglong,),x)
_py_box(x::Bool)    = ccall(:PyBool_FromLong,            Ptr{Cvoid}, (Clong,),     Clong(x))

_py_unbox(::Type{Float64}, r::Ptr{Cvoid}) = ccall(:PyFloat_AsDouble, Float64, (Ptr{Cvoid},), r)
_py_unbox(::Type{Float32}, r::Ptr{Cvoid}) = Float32(ccall(:PyFloat_AsDouble, Float64, (Ptr{Cvoid},), r))
_py_unbox(::Type{Int8},    r::Ptr{Cvoid}) = Int8(ccall(:PyLong_AsLongLong,  Clonglong, (Ptr{Cvoid},), r))
_py_unbox(::Type{Int16},   r::Ptr{Cvoid}) = Int16(ccall(:PyLong_AsLongLong, Clonglong, (Ptr{Cvoid},), r))
_py_unbox(::Type{Int32},   r::Ptr{Cvoid}) = Int32(ccall(:PyLong_AsLongLong, Clonglong, (Ptr{Cvoid},), r))
_py_unbox(::Type{Int64},   r::Ptr{Cvoid}) = ccall(:PyLong_AsLongLong, Clonglong, (Ptr{Cvoid},), r)
_py_unbox(::Type{UInt8},   r::Ptr{Cvoid}) = UInt8(ccall(:PyLong_AsUnsignedLongLong,  Culonglong, (Ptr{Cvoid},), r))
_py_unbox(::Type{UInt16},  r::Ptr{Cvoid}) = UInt16(ccall(:PyLong_AsUnsignedLongLong, Culonglong, (Ptr{Cvoid},), r))
_py_unbox(::Type{UInt32},  r::Ptr{Cvoid}) = UInt32(ccall(:PyLong_AsUnsignedLongLong, Culonglong, (Ptr{Cvoid},), r))
_py_unbox(::Type{UInt64},  r::Ptr{Cvoid}) = ccall(:PyLong_AsUnsignedLongLong, Culonglong, (Ptr{Cvoid},), r)
_py_unbox(::Type{Bool},    r::Ptr{Cvoid}) = ccall(:PyObject_IsTrue, Cint, (Ptr{Cvoid},), r) != 0

# Call the Python callable. Generated per concrete (Args, Ret): builds the arg
# tuple with unrolled _py_box calls, invokes PyObject_Call, unboxes via Ret.
# The generated body contains only ccalls and concrete _py_box/_py_unbox dispatch,
# so --trim=safe accepts it. The C shim released the GIL before calling Julia, so
# we re-acquire it here via PyGILState_Ensure.
@generated function (f::PyCallable{Args,Ret})(args...) where {Args,Ret}
    argtypes = (Args.parameters...,)
    nargs    = length(argtypes)
    if length(args) != nargs
        return :(error(string("PyCallable: expected ", $nargs, " argument(s), got ", $(length(args)))))
    end
    body = Expr(:block)
    push!(body.args, :(gstate = ccall(:PyGILState_Ensure, Int32, ())))
    push!(body.args, :(args_tup = ccall(:PyTuple_New, Ptr{Cvoid}, (Int,), $nargs)))
    push!(body.args, quote
        if args_tup == Ptr{Cvoid}(0)
            ccall(:PyGILState_Release, Cvoid, (Int32,), gstate)
            error("PyCallable: failed to build args tuple")
        end
    end)
    for i in 1:nargs
        Ti = argtypes[i]
        push!(body.args, quote
            local item = _py_box(convert($Ti, args[$i]))
            if item == Ptr{Cvoid}(0)
                ccall(:Py_DecRef, Cvoid, (Ptr{Cvoid},), args_tup)
                ccall(:PyGILState_Release, Cvoid, (Int32,), gstate)
                error("PyCallable: failed to box argument")
            end
            # PyTuple_SetItem steals the reference to `item`.
            ccall(:PyTuple_SetItem, Int32, (Ptr{Cvoid}, Int, Ptr{Cvoid}), args_tup, $(i - 1), item)
        end)
    end
    push!(body.args, quote
        local result = ccall(:PyObject_Call, Ptr{Cvoid},
                             (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}), f.ptr, args_tup, Ptr{Cvoid}(0))
        ccall(:Py_DecRef, Cvoid, (Ptr{Cvoid},), args_tup)
        if result == Ptr{Cvoid}(0)
            ccall(:PyErr_Clear, Cvoid, ())
            ccall(:PyGILState_Release, Cvoid, (Int32,), gstate)
            error("PyCallable: Python callable raised an exception")
        end
        local r = _py_unbox($Ret, result)
        ccall(:Py_DecRef, Cvoid, (Ptr{Cvoid},), result)
        if ccall(:PyErr_Occurred, Ptr{Cvoid}, ()) != C_NULL
            ccall(:PyErr_Clear, Cvoid, ())
            ccall(:PyGILState_Release, Cvoid, (Int32,), gstate)
            error("PyCallable: Python callable returned an incompatible value")
        end
        ccall(:PyGILState_Release, Cvoid, (Int32,), gstate)
        return r
    end)
    return body
end

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
        "String, Vector{String}, Vector{UInt8} (bytes), Vector{<numeric>}, " *
        "AbstractArray{<numeric>,N}, Dict{String,<scalar>}, " *
        "Tuple/NamedTuple of the above, Union{T,Nothing}, and @pyhandle isbitstype structs.\n" *
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
