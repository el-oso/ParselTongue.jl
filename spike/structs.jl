module StructABI

# Mirror of the carriers the plan introduces, to verify they cross @ccallable by value.
struct PtArray{T,N}
    data::Ptr{T}
    shape::NTuple{N,Int64}
    order::Cint
end

# Complex scalar round-trip (16-byte {double,double} struct by value).
Base.@ccallable function pt_conj(z::ComplexF64)::ComplexF64
    return conj(z)
end

# Receive a 2-D array carrier by value; return sum of elements as a sanity scalar.
# (Reverse the C-order shape to interpret the row-major buffer as column-major.)
Base.@ccallable function pt_arr_sum(a::PtArray{Float64,2})::Float64
    A = unsafe_wrap(Array, a.data, (Int(a.shape[2]), Int(a.shape[1])))  # reversed dims
    return sum(A)
end

# Return a struct by value: echo shape[1]*shape[2] and the order flag.
Base.@ccallable function pt_arr_ndims(a::PtArray{Float64,2})::Int64
    return a.shape[1] * a.shape[2] + Int64(a.order)
end

end # module
