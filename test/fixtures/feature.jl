using ParselTongue

# Opaque-handle type (item 12): isbits struct on C heap.
# mutable=true adds Py_tp_setattro so scalar fields are writable in-place (O6).
struct Pt2D
    x::Float64
    y::Float64
end
# subclass=true adds Py_TPFLAGS_BASETYPE so Python can subclass Pt2D (abi3-safe).
@pyhandle Pt2D mutable=true subclass=true

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

# __lt__ / __le__ (item O4): ordering by norm; __gt__ / __ge__ via Python reflection.
@pymethod __lt__ pt2d_lt(p::Pt2D, other::Pt2D)::Bool = (p.x^2 + p.y^2) < (other.x^2 + other.y^2)
@pymethod __le__ pt2d_le(p::Pt2D, other::Pt2D)::Bool = (p.x^2 + p.y^2) <= (other.x^2 + other.y^2)

# __new__ (item O5): constructor syntax Pt2D(x, y) instead of make_point(x, y).
@pymethod __new__ pt2d_new(x::Float64, y::Float64)::Pt2D = Pt2D(x, y)

# __setitem__ (O6): write back a new Pt2D via unsafe_store! (mutates in-place from Python).
@pymethod __setitem__ pt2d_setitem(p::Pt2D, i::Int64, val::Float64)::Pt2D =
    i == 0 ? Pt2D(val, p.y) : i == 1 ? Pt2D(p.x, val) : error("Pt2D index out of range: $i")

# __iter__ (O8a): self-iterator — C emits Py_INCREF(self); return self.
@pymethod __iter__ pt2d_iter(p::Pt2D)::Pt2D = p

# __contains__ (O8a): membership test (float in point).
@pymethod __contains__ pt2d_contains(p::Pt2D, val::Float64)::Bool = p.x == val || p.y == val

# @pyproperty (O10): computed read-only property.
@pyproperty Pt2D norm::Float64 (p -> sqrt(p.x^2 + p.y^2))

# Bound named method on an immutable @pyhandle: returns a new handle.
@pymethod translated(p::Pt2D, dx::Float64, dy::Float64)::Pt2D = Pt2D(p.x + dx, p.y + dy)

# Numeric dunders: binary ops (same-handle other) + unary ops.
@pymethod __add__ pt2d_add(p::Pt2D, q::Pt2D)::Pt2D = Pt2D(p.x + q.x, p.y + q.y)
@pymethod __sub__ pt2d_sub(p::Pt2D, q::Pt2D)::Pt2D = Pt2D(p.x - q.x, p.y - q.y)
@pymethod __mul__ pt2d_dot(p::Pt2D, q::Pt2D)::Float64 = p.x * q.x + p.y * q.y  # dot product
@pymethod __neg__ pt2d_neg(p::Pt2D)::Pt2D = Pt2D(-p.x, -p.y)
@pymethod __abs__ pt2d_abs(p::Pt2D)::Float64 = sqrt(p.x^2 + p.y^2)
# Mixed-type operators: T × scalar (p / k) and scalar × T (k * p, reflected).
@pymethod __truediv__ pt2d_divk(p::Pt2D, k::Float64)::Pt2D = Pt2D(p.x / k, p.y / k)
@pymethod __rmul__ pt2d_rscale(p::Pt2D, k::Float64)::Pt2D = Pt2D(p.x * k, p.y * k)

# LinearModel: callable handle (O8a __call__) + context manager (O9).
struct LinearModel
    w::Float64
    b::Float64
end
@pyhandle LinearModel
@pymethod __new__   lm_new(w::Float64, b::Float64)::LinearModel = LinearModel(w, b)
@pymethod __call__  lm_call(m::LinearModel, x::Float64)::Float64 = m.w * x + m.b
@pymethod __enter__ lm_enter(m::LinearModel)::LinearModel = m
@pymethod __exit__  lm_exit(m::LinearModel)::Bool = false

# O7 @pymutable: a mutable struct with a heap (String) field, backed by a Julia GC
# registry. Mutation via a module-level @pyfunc persists on the live object.
mutable struct Accumulator
    total::Float64
    label::String
end
@pymutable Accumulator
@pymethod __new__ acc_new(label::String)::Accumulator = Accumulator(0.0, label)
# Bound named methods: `acc.add(x)` mutates the live object; `acc.describe()` reads it.
@pymethod add!(a::Accumulator, x::Float64)::Float64 = (a.total += x; a.total)
@pymethod describe(a::Accumulator)::String = a.label

# O8b stateful iterator: @pymutable + __next__ advancing state in place.
mutable struct CountUp
    cur::Int64
    stop::Int64
end
@pymutable CountUp
@pymethod __new__  countup_new(stop::Int64)::CountUp = CountUp(0, stop)
@pymethod __iter__ countup_iter(c::CountUp)::CountUp = c
@pymethod __next__ countup_next(c::CountUp)::Union{Int64,Nothing} =
    c.cur >= c.stop ? nothing : (c.cur += 1; c.cur - 1)

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

    # Non-scalar callable signatures (item L): String and Vector{Float64}.
    @pyfunc apply_str(f::PyCallable{Tuple{String},String}, s::String)::String = f(s)
    @pyfunc apply_vec(f::PyCallable{Tuple{Vector{Float64}},Vector{Float64}}, v::Vector{Float64})::Vector{Float64} = f(v)

    # O7 @pymutable: mutate the live registry object; the change persists across calls.
    @pyfunc acc_add(a::Accumulator, x::Float64)::Float64 = (a.total += x; a.total)
    @pyfunc acc_total(a::Accumulator)::Float64 = a.total
end
