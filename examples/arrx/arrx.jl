using ParselTongue

@pymodule arrx begin
    @pyfunc sum_f64(v::Vector{Float64})::Float64 = sum(v)
    @pyfunc scale_f64(v::Vector{Float64}, k::Float64)::Vector{Float64} = v .* k
    @pyfunc cumsum_i64(v::Vector{Int64})::Vector{Int64} = cumsum(v)
    @pyfunc dot_f32(a::Vector{Float32}, b::Vector{Float32})::Float32 = sum(a .* b)
end
