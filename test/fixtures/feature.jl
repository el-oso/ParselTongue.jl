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
end
