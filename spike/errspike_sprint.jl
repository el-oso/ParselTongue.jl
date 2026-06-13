module ErrSpikeSprint
# Test: does sprint(showerror, e) get rejected by --trim=safe?
Base.@ccallable function pt_err_sprint(
        a::Int64, b::Int64,
        pt_err::Ptr{Int32})::Int64
    try
        a < 0 && error("negative input")
        unsafe_store!(pt_err, Int32(0))
        return a + b
    catch e
        unsafe_store!(pt_err, Int32(1))
        _ = sprint(showerror, e)
        return Int64(0)
    end
end
end
