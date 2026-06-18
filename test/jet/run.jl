# JET static-analysis gate (run with `julia --project=test/jet test/jet/run.jl`).
#
# Complements TypeContracts.check_trim_compat (which flags only dynamic-dispatch / trim
# hazards) by running JET's call analysis — it catches potential MethodErrors, undefined
# references, and type-inference failures *before runtime*, the closest Julia gets to a
# compile-time error check. Scoped to a curated set of type-stable internal marshalling
# functions (`from_c`/`to_c`/`_py_box`/`_py_unbox`); the FFI/`ccall`/`unsafe_*` surface is
# trusted (declared return types), and reports are filtered to ParselTongue via
# `target_modules` so Base/stdlib noise does not leak in.
using ParselTongue
using ParselTongue: from_c, to_c, c_abi_type, _py_box, _py_unbox
using JET
using Test

# Reports originating in ParselTongue for `f` called with the given concrete arg types.
reports(f, argtypes) = JET.get_reports(JET.report_call(f, argtypes; target_modules = (ParselTongue,)))

@testset "JET: marshaller call-analysis gate" begin
    # from_c / to_c for representative boundary carriers (the trim-compiled hot path).
    scalar_types = (Int8, Int16, Int32, Int64, UInt8, UInt16, UInt32, UInt64,
                    Float32, Float64, Bool, ComplexF32, ComplexF64)
    for T in scalar_types
        C = c_abi_type(T)
        @test isempty(reports(from_c, (Type{T}, C)))
        @test isempty(reports(to_c, (T,)))
    end

    @test isempty(reports(from_c, (Type{String}, Cstring)))
    @test isempty(reports(to_c, (String,)))

    for T in (Vector{Float64}, Vector{Int64}, Vector{String}, Dict{String,Float64})
        C = c_abi_type(T)
        @test isempty(reports(from_c, (Type{T}, C)))
        @test isempty(reports(to_c, (T,)))
    end

    # PyCallable building blocks (the @generated call operator is per-signature and is
    # exercised via these concrete box/unbox methods).
    for T in (Int64, Float64, Bool, String, Vector{Float64})
        @test isempty(reports(_py_box, (T,)))
        @test isempty(reports(_py_unbox, (Type{T}, Ptr{Cvoid})))
    end
end
