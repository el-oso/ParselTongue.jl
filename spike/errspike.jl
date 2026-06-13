module ErrSpike

# Spike: verify juliac --trim=safe accepts try/catch + out-parameter error signaling.
#
# Out-param convention:
#   *pt_err = 0 on success, non-zero on Julia exception
#   *pt_errmsg = malloc'd NUL-terminated string (caller must free), valid only when *pt_err != 0
#
# Test A: static fallback string (definitely trim-safe)
# Test B: type-narrowed ErrorException.msg (likely trim-safe)
# Test C: sprint(showerror, e) (likely fails --trim=safe due to dynamic dispatch)

# ── Helpers ─────────────────────────────────────────────────────────────────

# Copy a Julia String into a malloc'd C buffer. Returns Ptr{UInt8} (caller must free).
@noinline function _alloc_cstring(s::String)::Ptr{UInt8}
    n = sizeof(s)
    buf = Ptr{UInt8}(Libc.malloc(n + 1))
    buf == C_NULL && return C_NULL
    unsafe_copyto!(buf, pointer(s), n)
    unsafe_store!(buf, UInt8(0), n + 1)
    return buf
end

# ── Test A: catch without binding (static message) ───────────────────────────

Base.@ccallable function pt_err_static(
        a::Int64, b::Int64,
        pt_err::Ptr{Int32}, pt_errmsg::Ptr{Ptr{UInt8}})::Int64
    try
        a < 0 && error("negative input")
        unsafe_store!(pt_err, Int32(0))
        return a + b
    catch
        unsafe_store!(pt_err, Int32(1))
        unsafe_store!(pt_errmsg, _alloc_cstring("Julia exception"))
        return Int64(0)
    end
end

# ── Test B: catch e with ErrorException narrowing ────────────────────────────

Base.@ccallable function pt_err_msg(
        a::Int64, b::Int64,
        pt_err::Ptr{Int32}, pt_errmsg::Ptr{Ptr{UInt8}})::Int64
    try
        a < 0 && error("negative input")
        unsafe_store!(pt_err, Int32(0))
        return a + b
    catch e
        unsafe_store!(pt_err, Int32(1))
        msg = e isa ErrorException ? e.msg : "Julia exception"
        unsafe_store!(pt_errmsg, _alloc_cstring(msg))
        return Int64(0)
    end
end

# ── Test C: sprint(showerror, e) — expected to fail --trim=safe ──────────────
# Commented out so the whole file compiles; uncomment to test trim rejection.
#
# Base.@ccallable function pt_err_sprint(
#         a::Int64, b::Int64,
#         pt_err::Ptr{Int32}, pt_errmsg::Ptr{Ptr{UInt8}})::Int64
#     try
#         a < 0 && error("negative input")
#         unsafe_store!(pt_err, Int32(0))
#         return a + b
#     catch e
#         unsafe_store!(pt_err, Int32(1))
#         unsafe_store!(pt_errmsg, _alloc_cstring(sprint(showerror, e)))
#         return Int64(0)
#     end
# end

end # module ErrSpike
