module AddLib

# Minimal C-ABI entrypoint to de-risk the whole juliac --trim -> CPython pipeline.
Base.@ccallable function pt_add(a::Int64, b::Int64)::Int64
    return a + b
end

end # module
