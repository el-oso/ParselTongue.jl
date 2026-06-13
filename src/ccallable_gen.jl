# ── Julia-side @ccallable wrapper generation ──────────────────────────
#
# For each exported function we emit a `Base.@ccallable` wrapper whose argument
# and return types are the C-ABI carrier types. The wrapper converts incoming
# carriers to native values (`from_c`), calls the user function, and converts the
# result back (`to_c`). For scalars these conversions are the identity, so the
# wrapper compiles down to a direct call.
#
# Wrappers are generated as Julia *source text* because they are `include`d by
# juliac in a separate build process (see build.jl).

# A type rendered as parseable Julia source valid inside the generated entry
# (which only does `using ParselTongue`). Scalars/String/Cstring print back
# directly; the ParselTongue-owned carrier `PtArray{T,N}` is module-qualified.
# Returns Julia source text for a zero-valued instance of carrier C, used to
# initialize the result variable before the try block (the C shim discards this
# value when an error is signalled, but Julia's type system needs a valid return).
function _zero_cval(@nospecialize(C::Type))
    C === Cvoid   && return ""
    isscalar(C)   && return string("zero(", _type_src(C), ")")
    iscomplex(C)  && return string("zero(", _type_src(C), ")")
    C === Cstring && return "Cstring(Ptr{UInt8}(0))"
    C === ParselTongue.PtStrArray && return "ParselTongue.PtStrArray(Ptr{Ptr{UInt8}}(0), Int64(0))"
    C === ParselTongue.PtHandle && return "ParselTongue.PtHandle(Ptr{Cvoid}(0))"
    if isarray(C)
        T = _type_src(C.parameters[1])
        N = C.parameters[2]::Int
        shape = string("(", join(fill("Int64(0)", N), ", "), N == 1 ? "," : "", ")")
        return string(_type_src(C), "(Ptr{", T, "}(0), ", shape, ", Int32(0))")
    end
    if istuple(C)
        parts = [_zero_cval(S) for S in fieldtypes(C)]
        return string("(", join(parts, ", "), length(parts) == 1 ? "," : "", ")")
    end
    error("ParselTongue: _zero_cval: unhandled carrier $C")
end

function _type_src(@nospecialize(T::Type))
    if T isa DataType && T.name === PtArray.body.body.name
        return string("ParselTongue.PtArray{", _type_src(T.parameters[1]), ", ", T.parameters[2], "}")
    elseif T === PtStrArray
        # Always fully-qualify ParselTongue types to avoid ambiguity when the
        # caller has `using ParselTongue: PtStrArray` in scope (which causes
        # string(PtStrArray) to drop the module prefix in the current session).
        return "ParselTongue.PtStrArray"
    elseif T === PtHandle
        return "ParselTongue.PtHandle"
    elseif T isa DataType && T <: Tuple
        return string("Tuple{", join((_type_src(S) for S in fieldtypes(T)), ", "), "}")
    end
    # For user-defined types (not from Base, Core, or ParselTongue) return only
    # the bare type name. The juliac entry file include's the user source into
    # Main, so user types (including @pyhandle structs) are reachable by bare name.
    # Fully-qualified sandbox-module paths (e.g. Main.ParselTongueUserSandbox.Pt2D)
    # do not exist in the juliac subprocess and cause unresolved-call verifier errors.
    if T isa DataType && T.name.module ∉ (Base, Core, @__MODULE__)
        return String(T.name.name)
    end
    return string(T)
end

"""
    emit_ccallable(e::PtExport) -> String

Return the Julia source for the `Base.@ccallable` wrapper exporting `e`. The
wrapper references the user function by its bare name, so it must be emitted into
the same scope into which the user code was `include`d.
"""
function emit_ccallable(e::PtExport)
    sym   = cabi_symbol(e)
    ret_c = c_abi_type(e.ret)

    params = String[]
    pos_conv = String[]; kw_conv = String[]
    for a in e.args
        ci = c_abi_type(a.jl_type)
        push!(params, string(a.name, "::", _type_src(ci)))
        c = string("ParselTongue.from_c(", _type_src(a.jl_type), ", ", a.name, ")")
        if a.is_keyword
            push!(kw_conv, string(a.name, "=", c))
        else
            push!(pos_conv, c)
        end
    end
    # Trailing error out-parameters: signal exceptions to the C shim.
    push!(params, "_pt_err::Ptr{Int32}")
    push!(params, "_pt_errmsg::Ptr{Ptr{UInt8}}")

    call = if isempty(kw_conv)
        string(e.jl_func, "(", join(pos_conv, ", "), ")")
    else
        string(e.jl_func, "(", join(pos_conv, ", "), "; ", join(kw_conv, ", "), ")")
    end

    # Catch block: signal the error and copy the message into a malloc'd C buffer.
    # The C shim checks _pt_err, builds the Python exception, and frees the buffer.
    #
    # Nested isa checks are required for --trim=safe:
    #   _e::Any  (general catch; user function may throw any exception type)
    #   → isa ErrorException narrows _e to ErrorException
    #   → _e.msg::AbstractString (field is declared AbstractString in Julia base)
    #   → isa String narrows _m to String, making pointer/_n concrete
    # Without the inner `isa String`, assigning to ::String triggers
    # convert(String, ::AbstractString) which is dynamic dispatch.
    catch_stmts = string(
        "        unsafe_store!(_pt_err, Int32(1))\n",
        "        local _buf::Ptr{UInt8} = Ptr{UInt8}(0)\n",
        "        if _e isa ErrorException\n",
        "            local _m = _e.msg\n",
        "            if _m isa String\n",
        "                local _n::Int = sizeof(_m)\n",
        "                _buf = Ptr{UInt8}(Libc.malloc(_n + 1))\n",
        "                if _buf != C_NULL\n",
        "                    unsafe_copyto!(_buf, pointer(_m), _n)\n",
        "                    unsafe_store!(_buf, UInt8(0), _n + 1)\n",
        "                end\n",
        "            end\n",
        "        end\n",
        "        unsafe_store!(_pt_errmsg, _buf)\n",
    )

    sig = string("Base.@ccallable function ", sym, "(", join(params, ", "), ")")
    if ret_c === Cvoid
        return string(
            sig, "::Cvoid\n",
            "    try\n",
            "        ", call, "\n",
            "        unsafe_store!(_pt_err, Int32(0))\n",
            "    catch _e\n",
            catch_stmts,
            "    end\n",
            "    return\n",
            "end\n",
        )
    end
    ret_src  = _type_src(ret_c)
    zero_src = _zero_cval(ret_c)
    return string(
        sig, "::", ret_src, "\n",
        "    local _result::", ret_src, " = ", zero_src, "\n",
        "    try\n",
        "        _result = ParselTongue.to_c(", call, ")\n",
        "        unsafe_store!(_pt_err, Int32(0))\n",
        "    catch _e\n",
        catch_stmts,
        "    end\n",
        "    return _result\n",
        "end\n",
    )
end

"""
    emit_entry(exports, user_path) -> String

Return the full source of the juliac entry file: load ParselTongue, `include`
the user's source, then define every `@ccallable` wrapper. `user_path` must be
absolute (juliac's buildscript resolves includes relative to itself otherwise).
"""
function emit_entry(exports::AbstractVector{PtExport}, user_path::AbstractString)
    io = IOBuffer()
    println(io, "# Generated by ParselTongue — do not edit.")
    println(io, "using ParselTongue")
    println(io, "include(", repr(abspath(user_path)), ")")
    println(io)
    for e in exports
        println(io, emit_ccallable(e))
    end
    return String(take!(io))
end
