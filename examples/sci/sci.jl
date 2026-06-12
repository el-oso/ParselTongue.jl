using ParselTongue
using LinearAlgebra

@pymodule sci.linalg begin
    # AbstractMatrix => logical view (NumPy shape, correct for matmul; may copy for BLAS)
    @pyfunc matmul(A::AbstractMatrix{Float64}, B::AbstractMatrix{Float64})::Matrix{Float64} = A * B
    @pyfunc rowsums(A::AbstractMatrix{Float64})::Vector{Float64} = vec(sum(A, dims=2))
    @pyfunc normalize(v::Vector{Float64})::Vector{Float64} = v ./ sqrt(sum(abs2, v))
end

@pymodule sci.dsp begin
    @pyfunc conj_sum(z::Vector{ComplexF64})::ComplexF64 = sum(conj, z)
    @pyfunc scale!(x::Mut{Vector{Float64}}, k::Float64)::Nothing = (x .*= k; nothing)
    @pyfunc minmax(v::Vector{Float64})::Tuple{Float64,Float64} = (minimum(v), maximum(v))
end
