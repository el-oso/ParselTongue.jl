using ParselTongue

# Exercises every v1 boundary kind in one extension: scalars, strings, 1-D arrays.
@pymodule feature begin
    @pyfunc add(a::Int64, b::Int64)::Int64 = a + b
    @pyfunc is_even(n::Int64)::Bool = iseven(n)
    @pyfunc scale_f32(v::Float32, k::Float32)::Float32 = v * k
    @pyfunc greet(name::String)::String = "Hello, " * name * "!"
    @pyfunc sum_f64(xs::Vector{Float64})::Float64 = sum(xs)
    @pyfunc cumsum_i64(xs::Vector{Int64})::Vector{Int64} = cumsum(xs)
end
