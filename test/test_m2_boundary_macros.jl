using Test
using ParselTongue
using ParselTongue: assert_boundary, assert_ret_boundary, is_boundary_type,
                    c_abi_type, from_c, to_c, Mut,
                    PtExport, PtArray, emit_ccallable, emit_entry, emit_cshim,
                    _EXPORTS, clear_exports!, _default_py_name, submodule_names

@testset "boundary scalar impls" begin
    @test c_abi_type(Int64) === Int64
    @test c_abi_type(Float64) === Float64
    @test c_abi_type(Bool) === Bool
    @test from_c(Int64, 7) === 7
    @test to_c(3.5) === 3.5
    for T in (Int8, Int16, Int32, Int64, UInt8, UInt16, UInt32, UInt64, Float32, Float64, Bool)
        @test is_boundary_type(T)
        @test assert_boundary(T) === T
    end
end

@testset "non-boundary types rejected with a clear error" begin
    @test !is_boundary_type(Char)              # unsupported scalar
    @test !is_boundary_type(Dict{String,Int})
    err = try; assert_boundary(Dict{String,Int}); catch e; e; end
    @test err isa ErrorException
    @test occursin("cannot cross the Python boundary", err.msg)
end

@testset "@pyfunc records metadata and keeps the function callable" begin
    clear_exports!()
    @pyfunc add(a::Int, b::Int)::Int = a + b
    @pyfunc function mul(x::Float64, y::Float64)::Float64
        return x * y
    end
    @pyfunc "scaled" scale(v::Int32, k::Int32)::Int32 = v * k

    # Functions still work in Julia.
    @test add(40, 2) == 42
    @test mul(2.0, 3.0) == 6.0
    @test scale(Int32(3), Int32(4)) == Int32(12)

    # Metadata recorded.
    @test length(_EXPORTS) == 3
    names = [e.export_name for e in _EXPORTS]
    @test "add" in names && "mul" in names && "scaled" in names

    e_add = _EXPORTS[findfirst(e -> e.export_name == "add", _EXPORTS)]
    @test e_add.jl_func === :add
    @test [a.jl_type for a in e_add.args] == [Int, Int]
    @test e_add.ret === Int
    @test ParselTongue.cabi_symbol(e_add) == "pt_add"
end

@testset "@pyfunc rejects non-boundary signature at annotation time" begin
    clear_exports!()
    @test_throws ErrorException begin
        @eval @pyfunc bad(c::Char)::Int = Int(c)
    end
end

@testset "emit_ccallable produces a valid wrapper" begin
    clear_exports!()
    @pyfunc add(a::Int, b::Int)::Int = a + b
    src = emit_ccallable(_EXPORTS[1])
    # Error out-params are appended to the signature.
    @test occursin("pt_add(a::Int64, b::Int64, _pt_err::Ptr{Int32}, _pt_errmsg::Ptr{Ptr{UInt8}})::Int64", src)
    @test occursin("ParselTongue.from_c(Int64, a)", src)
    @test occursin("ParselTongue.to_c(add(", src)
    # try/catch error propagation is present.
    @test occursin("try", src)
    @test occursin("catch _e", src)
    @test occursin("unsafe_store!(_pt_err", src)
    # The emitted wrapper parses as valid Julia.
    @test Meta.parse(src) isa Expr
end

@testset "String boundary (M4)" begin
    @test is_boundary_type(String)
    @test c_abi_type(String) === Cstring
    @test from_c(String, Base.unsafe_convert(Cstring, "hi")) == "hi"
    cs = to_c("hi")
    @test cs isa Cstring
    @test unsafe_string(cs) == "hi"
    Libc.free(reinterpret(Ptr{Cvoid}, cs))   # to_c malloc's; free it
end

@testset "array boundary (1-D and N-D, dual policy)" begin
    @test is_boundary_type(Vector{Float64})
    @test is_boundary_type(Matrix{Float64})            # N-D
    @test is_boundary_type(AbstractMatrix{Float64})    # logical policy
    @test is_boundary_type(Vector{ComplexF64})         # complex elements
    @test !is_boundary_type(Vector{String})            # non-numeric eltype
    @test c_abi_type(Vector{Float64})  === PtArray{Float64,1}
    @test c_abi_type(Matrix{Float64})  === PtArray{Float64,2}
    @test c_abi_type(AbstractMatrix{Float64}) === PtArray{Float64,2}

    v = [1.0, 2.0, 3.0]
    b = to_c(v)
    @test b isa PtArray{Float64,1}
    @test b.shape == (3,)
    @test from_c(Vector{Float64}, b) == v
    Libc.free(Ptr{Cvoid}(b.data))

    # round-trip a 2-D array (returns are column-major / order=1)
    M = [1.0 2.0; 3.0 4.0]
    c2 = to_c(M)
    @test c2 isa PtArray{Float64,2}
    @test c2.shape == (2, 2) && c2.order == one(Cint)
    @test from_c(Matrix{Float64}, c2) == M     # F-order in -> natural dense
    Libc.free(Ptr{Cvoid}(c2.data))
end

@testset "emit_cshim handles scalars, strings, arrays" begin
    clear_exports!()
    @pyfunc add(a::Int64, b::Int64)::Int64 = a + b
    @pyfunc greet(s::String)::String = s
    @pyfunc scale(v::Vector{Float64}, k::Float64)::Vector{Float64} = v .* k
    c = ParselTongue.emit_cshim("demo", _EXPORTS)
    @test occursin("PyInit_demo", c)
    @test occursin("PyArg_ParseTuple", c)
    @test occursin("PyObject_GetBuffer", c)          # array arg
    @test occursin("typedef struct {", c)            # PtArray carrier struct
    @test occursin("frombuffer", c)                  # numpy-at-runtime return (zero-copy)
    @test occursin("_PtBuf", c)                      # zero-copy buffer owner type
    @test occursin("Py_BEGIN_ALLOW_THREADS", c)      # GIL released during Julia call
    @test occursin("PyUnicode_FromString", c)        # string return
end

@testset "emit_entry assembles a parseable entry file" begin
    clear_exports!()
    @pyfunc add(a::Int, b::Int)::Int = a + b
    tmp = tempname() * ".jl"
    write(tmp, "add(a,b) = a + b\n")
    entry = emit_entry(_EXPORTS, tmp)
    @test occursin("using ParselTongue", entry)
    @test occursin("include(", entry)
    @test occursin("pt_add", entry)
    @test Meta.parseall(entry) isa Expr
end

# ── Scientific-computing type expansion (Phases A–F) ──────────────────

@testset "complex boundary type" begin
    @test is_boundary_type(ComplexF64) && is_boundary_type(ComplexF32)
    @test c_abi_type(ComplexF64) === ComplexF64
    @test to_c(1.0 + 2.0im) === 1.0 + 2.0im
    @test is_boundary_type(Vector{ComplexF64})        # complex array elements
    @test c_abi_type(Vector{ComplexF64}) === PtArray{ComplexF64,1}
end

@testset "void (Nothing) returns" begin
    @test assert_ret_boundary(Nothing) === Cvoid
    clear_exports!()
    @pyfunc noop(n::Int64)::Nothing = nothing
    src = emit_ccallable(_EXPORTS[1])
    @test occursin("::Cvoid", src) && !occursin("to_c", src)
end

@testset "N-D dual policy carriers" begin
    @test c_abi_type(Matrix{Float64})         === PtArray{Float64,2}
    @test c_abi_type(AbstractMatrix{Float64}) === PtArray{Float64,2}
    @test c_abi_type(Array{Float32,3})        === PtArray{Float32,3}
    # logical view returns NumPy-shape indexing; dense returns reversed dims (C-order)
    M = [1.0 2.0 3.0; 4.0 5.0 6.0]            # 2x3 column-major
    c = to_c(M); @test c.shape == (2,3) && c.order == one(Cint)
    Libc.free(Ptr{Cvoid}(c.data))
end

@testset "Mut peels to inner type + flags mutable" begin
    clear_exports!()
    @pyfunc scale!(x::Mut{Vector{Float64}}, k::Float64)::Nothing = (x .*= k; nothing)
    e = _EXPORTS[1]
    @test e.export_name == "scale"              # `!` sanitized
    @test e.args[1].jl_type === Vector{Float64} # Mut peeled
    @test e.args[1].mutable == true
    v = [1.0, 2.0]; scale!(v, 3.0); @test v == [3.0, 6.0]   # still a real Julia fn
end

@testset "tuple returns" begin
    @test c_abi_type(Tuple{Int64,Float64}) === Tuple{Int64,Float64}
    @test assert_ret_boundary(Tuple{Float64,Vector{Float64}}) isa Type
    clear_exports!()
    @pyfunc mm(v::Vector{Float64})::Tuple{Float64,Float64} = (minimum(v), maximum(v))
    c = emit_cshim("demo", _EXPORTS)
    @test occursin("PtTuple", c) && occursin("PyTuple_Pack", c)
end

@testset "submodule namespacing + name sanitizing" begin
    @test _default_py_name("scale!") == "scale"
    @test _default_py_name("a!b?") == "a_b_"
    clear_exports!()
    @pymodule pkg.linalg begin
        @pyfunc solve(a::Int64)::Int64 = a
    end
    @pymodule pkg.stats begin
        @pyfunc mean(a::Float64)::Float64 = a
    end
    @test ParselTongue._MODULE_NAME[] == "pkg"
    @test Set(submodule_names(_EXPORTS)) == Set(["linalg", "stats"])
    @test _EXPORTS[findfirst(e -> e.export_name == "solve", _EXPORTS)].submodule == "linalg"
end
