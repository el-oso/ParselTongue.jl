using ParselTongue

# Fixture for the ASan glue gate (test/asan/). Each function returns one of the
# heap-owning carriers whose marshalling had memory bugs (A1 dict keys, A2 Optional
# Cstring, strarray, bytes, String), plus a tuple and a throwing function (error
# path → free(_pt_errmsg)). The bodies are never compiled by juliac here — only the
# @pyfunc *metadata* is used (emit_cshim), and the pt_* symbols are stubbed in C.
# The return-carrier exports are zero-arg to keep the C stubs trivial; `take` adds
# the dict *argument* path (its stub mimics Julia's from_c taking ownership).
@pymodule asan_carriers begin
    @pyfunc d()::Dict{String,Float64} = Dict("a" => 1.0, "b" => 2.0, "c" => 3.0)
    @pyfunc opt_some()::Union{String,Nothing} = "hello"
    @pyfunc opt_none()::Union{String,Nothing} = nothing
    @pyfunc strs()::Vector{String} = ["x", "y", "z"]
    @pyfunc bytes_()::Vector{UInt8} = UInt8[1, 2, 3, 4]
    @pyfunc s()::String = "result"
    @pyfunc tup()::Tuple{Float64,Int64} = (1.5, 7)
    @pyfunc boom()::Int64 = error("boom")
    # Dict *argument* path: exercises the __cleanup__ scope guard + post-call disarm
    # in _ap_dict. The driver calls this with a valid dict (success → stub frees →
    # disarm must prevent a double-free) and with bad input (error → guard frees).
    @pyfunc take(d::Dict{String,Float64})::Float64 = sum(values(d); init = 0.0)
end
