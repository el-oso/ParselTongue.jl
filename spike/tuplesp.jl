module TupleSpike
struct PtArray{T,N}
    data::Ptr{T}
    shape::NTuple{N,Int64}
    order::Cint
end
# tuple of (scalar, array-carrier) returned by value
Base.@ccallable function pt_pair()::Tuple{Float64, Int64}
    return (1.5, 7)
end
Base.@ccallable function pt_arrpair()::Tuple{Float64, PtArray{Float64,1}}
    p = Ptr{Float64}(Libc.malloc(3*8))
    unsafe_store!(p, 10.0, 1); unsafe_store!(p, 20.0, 2); unsafe_store!(p, 30.0, 3)
    return (99.0, PtArray{Float64,1}(p, (3,), Cint(1)))
end
end
