using Test
using ParselTongue
using ParselTongue: assert_boundary, is_boundary_type, c_abi_type, from_c, to_c,
                    PtExport, PtBuffer, emit_ccallable, emit_entry, _EXPORTS, clear_exports!

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
    @test occursin("Base.@ccallable function pt_add(a::Int64, b::Int64)::Int64", src)
    @test occursin("ParselTongue.from_c(Int64, a)", src)
    @test occursin("ParselTongue.to_c(add(", src)
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

@testset "1-D array boundary (M4)" begin
    @test is_boundary_type(Vector{Float64})
    @test is_boundary_type(Vector{Int64})
    @test !is_boundary_type(Vector{String})        # non-numeric eltype
    @test c_abi_type(Vector{Float64}) === PtBuffer{Float64}
    v = [1.0, 2.0, 3.0]
    b = to_c(v)
    @test b isa PtBuffer{Float64}
    @test b.len == 3
    back = from_c(Vector{Float64}, b)
    @test back == v
    Libc.free(Ptr{Cvoid}(b.data))
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
    @test occursin("typedef struct {", c)            # PtBuffer carrier struct
    @test occursin("frombuffer", c)                  # numpy-at-runtime return
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
