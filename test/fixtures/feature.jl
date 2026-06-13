using ParselTongue

# Exercises every v1.x boundary kind in one extension: scalars, strings, complex,
# 1-D and N-D arrays (both policies), in-place mutation + void, and tuple returns.
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
end
