using ParselTongue

# Opaque-handle type (item 12): immutable isbits struct on C heap.
# Constructor @pyfunc returns a PyCapsule; method @pyfuncs receive/return handles.
# Mutation is functional — each "update" returns a new handle.
struct Pt2D
    x::Float64
    y::Float64
end
@pyhandle Pt2D

# Custom repr via @pymethod (item J): overrides the generated "<Pt2D>" default.
@pymethod __repr__ pt2d_repr(p::Pt2D)::String = string("<Pt2D: x=", p.x, ", y=", p.y, ">")

# Additional dunder methods (item O): __len__, __hash__, __bool__.
@pymethod __len__  pt2d_len(p::Pt2D)::Int64  = Int64(round(sqrt(p.x^2 + p.y^2)))
@pymethod __hash__ pt2d_hash(p::Pt2D)::Int64 = hash((p.x, p.y)) % Int64(typemax(Int64))
@pymethod __bool__ pt2d_bool(p::Pt2D)::Bool  = p.x != 0.0 || p.y != 0.0

# __getitem__ (item O2): index into Pt2D as a 2-element sequence (0-based).
@pymethod __getitem__ pt2d_getitem(p::Pt2D, i::Int64)::Float64 =
    i == 0 ? p.x : i == 1 ? p.y : error("Pt2D index out of range: $i")

# __eq__ (item O3): value equality; __ne__ is auto-negated.
@pymethod __eq__ pt2d_eq(p::Pt2D, other::Pt2D)::Bool = p.x == other.x && p.y == other.y

# Exercises every v1.x boundary kind in one extension: scalars, strings, complex,
# 1-D and N-D arrays (both policies), in-place mutation + void, tuple returns,
# and opaque handles.
@pymodule feature begin
    @pyfunc add(a::Int64, b::Int64)::Int64 = a + b
    @pyfunc is_even(n::Int64)::Bool = iseven(n)
    @pyfunc greet(name::String)::String = "Hello, " * name * "!"
    @pyfunc conj1(z::ComplexF64)::ComplexF64 = conj(z)

    @pyfunc sum_f64(xs::Vector{Float64})::Float64 = sum(xs)
    @pyfunc rowsums(A::AbstractMatrix{Float64})::Vector{Float64} = vec(sum(A, dims=2))
    @pyfunc dims(A::Matrix{Float64})::Vector{Int64} = Int64[size(A,1), size(A,2)]

    @pyfunc scale!(x::Mut{Vector{Float64}}, k::Float64)::Nothing = (x .*= k; nothing)
    @pyfunc minmax(v::Vector{Float64})::Tuple{Float64,Float64} = (minimum(v), maximum(v))

    @pyfunc boom()::Int64 = error("boom!")
    @pyfunc safe_div(a::Float64, b::Float64)::Float64 = b == 0.0 ? error("division by zero") : a / b
    @pyfunc sleep_ms(ms::Int64)::Int64 = (Libc.systemsleep(ms / 1000.0); ms)

    # Keyword / default arguments (item 5).
    @pyfunc power(base::Float64; exponent::Float64=2.0)::Float64 = base ^ exponent
    @pyfunc clamp_val(x::Float64; lo::Float64=0.0, hi::Float64=1.0)::Float64 = clamp(x, lo, hi)

    # Vector{String} <-> list[str] (item 8).
    @pyfunc words(s::String)::Vector{String} = String.(split(s))
    @pyfunc join_words(ws::Vector{String})::String = join(ws, " ")

    # NamedTuple <-> dict return (item 8).
    @pyfunc describe(v::Vector{Float64})::NamedTuple{(:min, :max, :n), Tuple{Float64, Float64, Int64}} =
        (min=minimum(v), max=maximum(v), n=Int64(length(v)))

    # Opaque handle types (item 12): Pt2D is an isbitstype struct on the C heap.
    @pyfunc make_point(x::Float64, y::Float64)::Pt2D = Pt2D(x, y)
    @pyfunc point_x(p::Pt2D)::Float64 = p.x
    @pyfunc point_y(p::Pt2D)::Float64 = p.y
    @pyfunc point_norm(p::Pt2D)::Float64 = sqrt(p.x^2 + p.y^2)
    @pyfunc point_scale(p::Pt2D, k::Float64)::Pt2D = Pt2D(p.x * k, p.y * k)

    # Python callables as arguments (item F): accept a Python callable and call it.
    @pyfunc apply(f::PyCallable, x::Float64)::Float64 = f(x)
    @pyfunc bisect(f::PyCallable, lo::Float64, hi::Float64)::Float64 = begin
        for _ in 1:52
            mid = (lo + hi) / 2.0
            f(mid) < 0.0 ? (lo = mid) : (hi = mid)
        end
        (lo + hi) / 2.0
    end

    # Arbitrary callable signatures (item L): two Int64 args → Int64.
    @pyfunc combine(f::PyCallable{Tuple{Int64,Int64},Int64}, a::Int64, b::Int64)::Int64 = f(a, b)
end
