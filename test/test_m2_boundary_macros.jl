using Test
using ParselTongue
using ParselTongue: assert_boundary, assert_ret_boundary, is_boundary_type,
                    c_abi_type, from_c, to_c, Mut, PtHandle,
                    PtExport, PtArray, emit_ccallable, emit_entry, emit_cshim,
                    _EXPORTS, clear_exports!, _default_py_name, submodule_names,
                    _julia_version_str, _runtime_wheel_tag, _runtime_metadata,
                    _RUNTIME_INIT_PY, _write_shared_pkg_pyfiles,
                    _readelf_needed, _transitive_needed, _resolve_soname,
                    _vendor_libs_smart,
                    PtOpt, _is_optional, _opt_inner, isopt, _opt_inner_c,
                    _to_c_opt,
                    PtError, _ERRORS, _py_exc_cname, _error_globals, _error_inits,
                    PtDict, isdict, _dict_val_c, _dict_structs, _uses_bytes,
                    _manylinux_plat, _wheel_tag, _wheel_tag_abi3

# Defined at file scope so Core.eval can resolve it during @pyhandle macro expansion.
struct _TestHandle
    x::Float64
    n::Int64
end
@pyhandle _TestHandle

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
    @test !is_boundary_type(Char)                  # unsupported scalar
    @test !is_boundary_type(Dict{String,Any})      # Any value type not supported
    @test !is_boundary_type(Dict{Int,Float64})     # non-String key not supported
    err = try; assert_boundary(Dict{String,Any}); catch e; e; end
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
    @test is_boundary_type(Vector{String})             # string arrays now supported (item 8)
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

@testset "keyword/default arguments (item 5)" begin
    clear_exports!()
    # Positional-arg default (b::T = val syntax).
    @pyfunc add_def(a::Int64, b::Int64=10)::Int64 = a + b
    # Keyword arg via ; syntax.
    @pyfunc power(base::Float64; exponent::Float64=2.0)::Float64 = base ^ exponent

    @test add_def(1, 2) == 3
    @test add_def(1) == 11      # Julia: default actually works
    @test power(3.0) ≈ 9.0
    @test power(3.0; exponent=3.0) ≈ 27.0

    e_add = _EXPORTS[findfirst(e -> e.export_name == "add_def", _EXPORTS)]
    @test e_add.args[1].default === nothing   # a is required
    @test e_add.args[2].default === 10        # b has default

    e_pow = _EXPORTS[findfirst(e -> e.export_name == "power", _EXPORTS)]
    @test e_pow.args[1].default === nothing       # base is required
    @test e_pow.args[2].default ≈ 2.0            # exponent has default

    # C shim emits METH_KEYWORDS and PyArg_ParseTupleAndKeywords.
    c = emit_cshim("demo", _EXPORTS)
    @test occursin("METH_VARARGS | METH_KEYWORDS", c)
    @test occursin("PyArg_ParseTupleAndKeywords", c)
    @test occursin("_kwlist", c)
    # Required-before-optional constraint is enforced.
    err = try; @eval @pyfunc bad2(a::Int64=1, b::Int64)::Int64 = a + b; nothing
         catch e; e; end
    @test (err isa LoadError ? err.error : err) isa ErrorException
end

@testset "Vector{String} boundary (item 8)" begin
    @test is_boundary_type(Vector{String})
    @test c_abi_type(Vector{String}) === ParselTongue.PtStrArray

    # round-trip
    v = ["hello", "world", ""]
    c = to_c(v)
    @test c isa ParselTongue.PtStrArray
    @test c.len == 3
    v2 = from_c(Vector{String}, c)
    @test v2 == v
    # to_c mallocs; the C shim frees in practice, but free manually here
    for i in 1:c.len
        Libc.free(unsafe_load(c.data, i))
    end
    Libc.free(c.data)

    # cshim emits the PtStrArray helper
    clear_exports!()
    @pyfunc words(s::String)::Vector{String} = split(s)
    @pyfunc join_words(ws::Vector{String})::String = join(ws, " ")
    c = emit_cshim("demo", _EXPORTS)
    @test occursin("PtStrArray", c)
    @test occursin("_pt_strarray_to_list", c)
    @test occursin("_pt_free_str_array", c)
    @test occursin("PyList_Check", c)     # arg validation
    @test occursin("PyUnicode_AsUTF8AndSize", c)
end

@testset "opaque handle types (@pyhandle, item 12)" begin
    # @pyhandle rejects non-isbits types (Int is a primitive, not isbitstype-wrappable).
    err = try; @eval @pyhandle String; catch e; e; end
    @test (err isa LoadError ? err.error : err) isa ErrorException

    # Boundary protocol is now complete (registered at file scope above).
    @test is_boundary_type(_TestHandle)
    @test c_abi_type(_TestHandle) === ParselTongue.PtHandle
    @test assert_ret_boundary(_TestHandle) === ParselTongue.PtHandle

    # Round-trip: to_c mallocs a copy; from_c loads it back.
    orig = _TestHandle(3.14, 42)
    h = to_c(orig)
    @test h isa PtHandle
    @test h.ptr != Ptr{Cvoid}(0)
    recovered = from_c(_TestHandle, h)
    @test recovered === orig
    Libc.free(h.ptr)   # to_c malloc's; free manually in the test

    # @pyfunc records correct carrier type for handle args/returns.
    clear_exports!()
    @pyfunc make_th(x::Float64, n::Int64)::_TestHandle = _TestHandle(x, n)
    @pyfunc get_x(h::_TestHandle)::Float64 = h.x
    @pyfunc update_n(h::_TestHandle, n::Int64)::_TestHandle = _TestHandle(h.x, n)

    @test length(_EXPORTS) == 3
    e_make = _EXPORTS[findfirst(e -> e.export_name == "make_th", _EXPORTS)]
    @test c_abi_type(e_make.ret) === ParselTongue.PtHandle
    e_get  = _EXPORTS[findfirst(e -> e.export_name == "get_x",  _EXPORTS)]
    @test c_abi_type(e_get.args[1].jl_type) === ParselTongue.PtHandle

    # emit_ccallable: return type and param type are ParselTongue.PtHandle.
    src = emit_ccallable(e_make)
    @test occursin("ParselTongue.PtHandle", src)
    @test Meta.parse(src) isa Expr

    # C shim emits capsule helpers and PtHandle typedef.
    c = emit_cshim("demo", _EXPORTS)
    @test occursin("typedef struct { void *ptr; } PtHandle;", c)
    @test occursin("_pt_capsule_free", c)
    @test occursin("PyCapsule_New", c)        # constructor return
    @test occursin("PyCapsule_CheckExact", c) # method arg validation
    @test occursin("PyCapsule_GetPointer", c) # handle extraction
end

@testset "NamedTuple return (item 8)" begin
    @test assert_ret_boundary(NamedTuple{(:x, :y), Tuple{Float64, Int64}}) isa Type
    clear_exports!()
    @pyfunc stats(v::Vector{Float64})::NamedTuple{(:min, :max, :n), Tuple{Float64, Float64, Int64}} =
        (min=minimum(v), max=maximum(v), n=length(v))
    c = emit_cshim("demo", _EXPORTS)
    @test occursin("PyDict_New", c)
    @test occursin("PyDict_SetItemString", c)
    @test occursin("\"min\"", c) && occursin("\"max\"", c) && occursin("\"n\"", c)
end

@testset "abi3 stable-ABI shim (item 2)" begin
    clear_exports!()
    @pyfunc add(a::Int64, b::Int64)::Int64 = a + b
    @pyfunc greet(s::String)::String = string("hello ", s)
    @pyfunc scale(v::Vector{Float64}, k::Float64)::Vector{Float64} = v .* k
    @pyfunc words(s::String)::Vector{String} = split(s)

    c_default = emit_cshim("demo", _EXPORTS)
    c_abi3    = emit_cshim("demo", _EXPORTS; abi3=true)

    # abi3 shim defines the limited-API guard; default does not.
    @test  occursin("#define Py_LIMITED_API 0x030B0000", c_abi3)
    @test !occursin("#define Py_LIMITED_API",            c_default)

    # Both use PyType_Spec / PyType_FromSpec (the unified approach).
    @test occursin("PyType_Spec",     c_abi3)
    @test occursin("PyType_FromSpec", c_abi3)
    @test occursin("PyType_Spec",     c_default)
    @test occursin("PyType_FromSpec", c_default)

    # Neither uses macros that are absent under Py_LIMITED_API.
    for macro_name in ("PyObject_New", "PyVarObject_HEAD_INIT",
                       "PyList_GET_SIZE", "PyList_GET_ITEM",
                       "PyList_SET_ITEM", "PyTuple_SET_ITEM")
        @test !occursin(macro_name, c_abi3)
        @test !occursin(macro_name, c_default)
    end

    # Function-form equivalents ARE present (used for list/tuple operations).
    @test occursin("PyList_SetItem",  c_abi3)
    @test occursin("PyTuple_SetItem", c_abi3)
end

@testset "slim vendoring helpers (item 9)" begin
    # _readelf_needed on a real Julia lib should return a non-empty soname list.
    julia_lib = abspath(joinpath(Sys.BINDIR, "..", "lib", "julia"))
    libjulia_int = filter(n -> startswith(n, "libjulia-internal") && !occursin(".a", n) &&
                                isfile(joinpath(julia_lib, n)) && !islink(joinpath(julia_lib, n)),
                          readdir(julia_lib))
    if !isempty(libjulia_int)
        needs = _readelf_needed(joinpath(julia_lib, first(libjulia_int)))
        @test !isempty(needs)
        # libjulia-internal must not DT_NEED OpenBLAS or SuiteSparse/cholmod (item 9 claim).
        @test !any(n -> occursin("openblas", lowercase(n)), needs)
        @test !any(n -> occursin("cholmod",  lowercase(n)), needs)
    end

    # _resolve_soname: should find libjulia in the Julia lib dirs.
    lib_dirs = [abspath(joinpath(Sys.BINDIR, "..", "lib")),
                abspath(joinpath(Sys.BINDIR, "..", "lib", "julia"))]
    libjulia_sonames = filter(n -> startswith(n, "libjulia.so"),
                              readdir(first(lib_dirs)))
    if !isempty(libjulia_sonames)
        resolved = _resolve_soname(first(libjulia_sonames), lib_dirs)
        @test resolved !== nothing
        @test isfile(resolved)
    end

    # _vendor_libs_smart: only copies files whose soname is in `needed`.
    src = mktempdir(); dst = mktempdir()
    try
        # Create two fake .so files; only one is in needed.
        write(joinpath(src, "libfoo.so.1"), "foo")
        write(joinpath(src, "libbar.so.1"), "bar")
        needed = Set(["libfoo.so.1"])
        _vendor_libs_smart(src, dst, needed)
        @test  isfile(joinpath(dst, "libfoo.so.1"))
        @test !isfile(joinpath(dst, "libbar.so.1"))
    finally
        rm(src; recursive=true); rm(dst; recursive=true)
    end
end

@testset "shared-runtime wheel helpers (item 4)" begin
    # _julia_version_str returns the current Julia version.
    jver = _julia_version_str()
    @test jver == string(VERSION)
    @test occursin(r"^\d+\.\d+\.\d+", jver)

    # _runtime_wheel_tag returns "py3-none-<plat>".
    python = get(ENV, "PYTHON3", "python3")
    rtag = _runtime_wheel_tag(python)
    @test startswith(rtag, "py3-none-")
    @test !occursin("cp3", rtag)          # must NOT be CPython-specific

    # _runtime_metadata has correct fields.
    meta = _runtime_metadata("1.12.6", "1.12.6")
    @test occursin("Name: parseltongue-runtime", meta)
    @test occursin("Version: 1.12.6", meta)
    @test occursin("1.12.6", meta)

    # _RUNTIME_INIT_PY is valid Python that defines _JULIA_LIB.
    @test occursin("_JULIA_LIB", _RUNTIME_INIT_PY)
    @test occursin("_JULIA_LIB_JULIA", _RUNTIME_INIT_PY)
    # Must be a valid Python docstring (triple double-quotes).
    @test startswith(strip(_RUNTIME_INIT_PY), "\"\"\"")

    # _write_shared_pkg_pyfiles generates __init__.py with LD_LIBRARY_PATH logic.
    clear_exports!()
    @pyfunc _test_shared_add(a::Float64, b::Float64)::Float64 = a + b
    pkgdir = mktempdir()
    try
        _write_shared_pkg_pyfiles(pkgdir, "_mymod", _EXPORTS, "mymod")
        init = read(joinpath(pkgdir, "__init__.py"), String)
        @test occursin("parseltongue_runtime", init)
        @test occursin("LD_LIBRARY_PATH", init)
        @test occursin("_preload", init)
        @test occursin("_test_shared_add", init)
        @test occursin("__all__", init)
        # Docstring uses triple double-quotes.
        @test occursin("\"\"\"", init)
    finally
        rm(pkgdir; recursive=true)
    end
end

@testset "Optional{T} boundary types (item C)" begin
    # ── boundary.jl helpers ──────────────────────────────────────────────
    @test _is_optional(Union{Float64, Nothing})
    @test _is_optional(Union{Nothing, Int32})
    @test !_is_optional(Float64)
    @test !_is_optional(String)

    @test _opt_inner(Union{Float64, Nothing}) === Float64
    @test _opt_inner(Union{Nothing, Int32})  === Int32

    # c_abi_type returns PtOpt{inner_carrier}
    @test c_abi_type(Union{Float64, Nothing}) === PtOpt{Float64}
    @test c_abi_type(Union{Int64, Nothing})   === PtOpt{Int64}
    @test c_abi_type(Union{String, Nothing})  === PtOpt{Cstring}

    # PtOpt is isbitstype for scalar inner types (trim-safe)
    @test isbitstype(PtOpt{Float64})
    @test isbitstype(PtOpt{Int64})

    # isopt / _opt_inner_c on carriers
    @test isopt(PtOpt{Float64})
    @test !isopt(Float64)
    @test _opt_inner_c(PtOpt{Float64}) === Float64
    @test _opt_inner_c(PtOpt{Cstring}) === Cstring

    # from_c: has_value=0 → nothing; has_value=1 → inner value
    @test from_c(Union{Float64, Nothing}, PtOpt{Float64}(Int32(0), 0.0)) === nothing
    @test from_c(Union{Float64, Nothing}, PtOpt{Float64}(Int32(1), 3.14)) === 3.14
    @test from_c(Union{Int64, Nothing},  PtOpt{Int64}(Int32(0), Int64(0))) === nothing
    @test from_c(Union{Int64, Nothing},  PtOpt{Int64}(Int32(1), Int64(7))) === Int64(7)

    # _to_c_opt: nothing → {0,0}; value → {1, to_c(x)}
    @test _to_c_opt(PtOpt{Float64}, nothing) === PtOpt{Float64}(Int32(0), 0.0)
    @test _to_c_opt(PtOpt{Float64}, 3.14)    === PtOpt{Float64}(Int32(1), 3.14)
    @test _to_c_opt(PtOpt{Int64},   nothing) === PtOpt{Int64}(Int32(0), Int64(0))
    @test _to_c_opt(PtOpt{Int64},   Int64(5)) === PtOpt{Int64}(Int32(1), Int64(5))

    # is_boundary_type / assert_boundary accept Optional types
    @test is_boundary_type(Union{Float64, Nothing})
    @test is_boundary_type(Union{String, Nothing})
    @test assert_ret_boundary(Union{Float64, Nothing}) === PtOpt{Float64}

    # ── ccallable_gen.jl ─────────────────────────────────────────────────
    clear_exports!()
    @pyfunc opt_in(x::Union{Float64,Nothing})::Float64 =
        x === nothing ? -1.0 : x + 1.0
    @pyfunc opt_out(x::Float64)::Union{Float64,Nothing} =
        x < 0 ? nothing : x * 2

    e_in  = _EXPORTS[findfirst(e -> e.export_name == "opt_in",  _EXPORTS)]
    e_out = _EXPORTS[findfirst(e -> e.export_name == "opt_out", _EXPORTS)]

    src_in = emit_ccallable(e_in)
    @test occursin("PtOpt{Float64}", src_in)
    @test occursin("from_c(Union{", src_in)   # Union order varies; just check presence

    src_out = emit_ccallable(e_out)
    @test occursin("PtOpt{Float64}", src_out)
    @test occursin("_to_c_opt(", src_out)

    # ── cshim.jl ─────────────────────────────────────────────────────────
    shim = emit_cshim("optmod", _EXPORTS[end-1:end])

    # Struct typedef emitted
    @test occursin("PtOpt_double", shim)
    @test occursin("int32_t has_value", shim)

    # Arg plan: parse with "O", check Py_None, fill struct
    @test occursin("PyArg_Parse", shim)          # inner extraction
    @test occursin("Py_None", shim)              # None check

    # Return plan: check has_value, return Py_None or inner
    @test occursin("Py_INCREF(Py_None)", shim)
    @test occursin("PyFloat_FromDouble", shim)
end

@testset "custom exception types (@pyerror, item A)" begin
    # ── _py_exc_cname helper ─────────────────────────────────────────────
    @test _py_exc_cname(:Exception)      == "PyExc_Exception"
    @test _py_exc_cname(:ValueError)     == "PyExc_ValueError"
    @test _py_exc_cname(:ArithmeticError)== "PyExc_ArithmeticError"
    @test _py_exc_cname(:RuntimeError)   == "PyExc_RuntimeError"
    err = try; _py_exc_cname(:NoSuchError); catch e; e; end
    @test err isa ErrorException
    @test occursin("NoSuchError", err.msg)

    # ── @pyerror populates _ERRORS ───────────────────────────────────────
    clear_exports!()
    @test isempty(_ERRORS)

    @pyerror DomainError
    @test length(_ERRORS) == 1
    @test _ERRORS[1].jl_type === DomainError
    @test _ERRORS[1].py_name == "DomainError"
    @test _ERRORS[1].parent  == "PyExc_Exception"

    @pyerror ArgumentError <: ValueError
    @test length(_ERRORS) == 2
    @test _ERRORS[2].jl_type === ArgumentError
    @test _ERRORS[2].py_name == "ArgumentError"
    @test _ERRORS[2].parent  == "PyExc_ValueError"

    # clear_exports! empties _ERRORS too
    clear_exports!()
    @test isempty(_ERRORS)
    @test isempty(_EXPORTS)

    # ── ccallable_gen.jl: catch block with errors ─────────────────────────
    clear_exports!()
    @pyerror DomainError
    @pyerror ArgumentError <: ValueError
    @pyfunc typed_exc(x::Float64)::Float64 = x < 0 ? throw(DomainError(x, "negative")) : x

    e = _EXPORTS[1]
    errs = copy(_ERRORS)

    src_no_errors = emit_ccallable(e)
    # Without errors: only code 1 (RuntimeError)
    @test occursin("Int32(1)", src_no_errors)
    @test !occursin("Int32(2)", src_no_errors)

    src_with_errors = emit_ccallable(e; errors=errs)
    # With errors: code 2 for DomainError, code 3 for ArgumentError, else code 1
    @test occursin("Int32(2)", src_with_errors)
    @test occursin("Int32(3)", src_with_errors)
    @test occursin("DomainError", src_with_errors)
    @test occursin("ArgumentError", src_with_errors)
    # Fallback still present
    @test occursin("Int32(1)", src_with_errors)

    # ── cshim.jl: error globals and PyInit code ───────────────────────────
    eglobals = _error_globals(errs)
    @test length(eglobals) == 2
    @test occursin("pt_err_DomainError", eglobals[1])
    @test occursin("pt_err_ArgumentError", eglobals[2])

    einits = _error_inits("mymod", errs)
    @test any(s -> occursin("PyErr_NewException", s) && occursin("mymod.DomainError", s), einits)
    @test any(s -> occursin("PyExc_ValueError", s), einits)
    @test any(s -> occursin("PyModule_AddObject", s) && occursin("\"DomainError\"", s), einits)

    shim = emit_cshim("mymod", _EXPORTS, errs)
    @test occursin("static PyObject *pt_err_DomainError = NULL;", shim)
    @test occursin("static PyObject *pt_err_ArgumentError = NULL;", shim)
    @test occursin("PyErr_NewException(\"mymod.DomainError\"", shim)
    @test occursin("PyErr_NewException(\"mymod.ArgumentError\"", shim)
    @test occursin("PyExc_ValueError", shim)
    # Error dispatch in wrapper
    @test occursin("_pt_err == 2", shim)
    @test occursin("_pt_err == 3", shim)
    @test occursin("PyExc_RuntimeError", shim)   # fallback

    # Without errors: shim returns PyModule_Create directly
    shim_bare = emit_cshim("baremod", _EXPORTS)
    @test occursin("return PyModule_Create", shim_bare)
    @test !occursin("PyErr_NewException", shim_bare)
end

@testset "Dict{String,V} + bytes boundary types (item B)" begin
    # ── is_boundary_type for all registered value types ───────────────
    for V in (Int8, Int16, Int32, Int64, UInt8, UInt16, UInt32, UInt64,
              Float32, Float64, Bool)
        @test is_boundary_type(Dict{String,V})
    end
    @test !is_boundary_type(Dict{String,String})   # String val not yet supported
    @test !is_boundary_type(Dict{String,Any})       # unsupported val type
    @test !is_boundary_type(Dict{Int,Float64})      # non-String key not supported

    # ── PtDict carrier ────────────────────────────────────────────────
    @test c_abi_type(Dict{String,Float64}) === PtDict{Float64}
    @test c_abi_type(Dict{String,Int32})   === PtDict{Int32}
    @test isdict(PtDict{Float64})
    @test !isdict(Float64)
    @test _dict_val_c(PtDict{Float64}) === Float64
    @test _dict_val_c(PtDict{Int32})   === Int32

    # ── round-trip Dict{String,Float64} ──────────────────────────────
    d = Dict{String,Float64}("a" => 1.0, "b" => 2.5)
    cv = to_c(d)
    @test cv isa PtDict{Float64}
    @test cv.len == 2
    d2 = from_c(Dict{String,Float64}, cv)   # from_c frees the C arrays
    @test d2 == d

    # ── round-trip Dict{String,Int32} ────────────────────────────────
    d3 = Dict{String,Int32}("x" => Int32(7), "y" => Int32(-3))
    cv3 = to_c(d3)
    @test cv3 isa PtDict{Int32}
    d4 = from_c(Dict{String,Int32}, cv3)
    @test d4 == d3

    # ── bytes: Vector{UInt8} uses the array carrier (c_abi_type) ─────
    @test is_boundary_type(Vector{UInt8})
    @test c_abi_type(Vector{UInt8}) === PtArray{UInt8,1}

    # ── cshim.jl: bytes helper + dict codegen ─────────────────────────
    clear_exports!()
    @pyfunc b_encode(s::String)::Vector{UInt8} = Vector{UInt8}(s)
    @pyfunc b_dict_str(opts::Dict{String,Float64})::String =
        join(string(k) for k in sort(collect(keys(opts))))

    @test _uses_bytes(_EXPORTS)
    c = emit_cshim("bmod", _EXPORTS)

    # bytes helper emitted for Vector{UInt8} return
    @test occursin("_pt_make_bytes", c)
    @test occursin("PyBytes_FromStringAndSize", c)

    # dict struct typedef emitted
    @test occursin("PtDict_double", c)
    dstructs = _dict_structs(_EXPORTS)
    @test any(s -> occursin("PtDict_double", s), dstructs)
    @test any(s -> occursin("char **keys", s), dstructs)

    # dict arg: validate with PyDict_Check, iterate with PyDict_Next
    @test occursin("PyDict_Check", c)
    @test occursin("PyDict_Next", c)
    @test occursin("PyFloat_AsDouble", c)         # Float64 value extraction
    @test occursin("PyUnicode_AsUTF8AndSize", c)  # key extraction

    # _uses_bytes false when no Vector{UInt8} return present
    clear_exports!()
    @pyfunc no_bytes(s::String)::String = s
    @test !_uses_bytes(_EXPORTS)
end

@testset "manylinux tagging (item 6)" begin
    python = get(ENV, "PYTHON3", "python3")

    # ── _manylinux_plat ──────────────────────────────────────────────
    # manylinux=false → raw "linux_ARCH" (no substitution)
    plat_raw = _manylinux_plat(python; manylinux=false)
    if Sys.islinux()
        @test startswith(plat_raw, "linux_")
        @test !startswith(plat_raw, "manylinux_")
    end

    # manylinux="2.17" → pinned floor
    plat_pinned = _manylinux_plat(python; manylinux="2.17")
    if Sys.islinux()
        @test startswith(plat_pinned, "manylinux_2_17_")
        arch = plat_raw[length("linux_")+1:end]
        @test plat_pinned == "manylinux_2_17_$arch"
    end

    # manylinux=true → auto-detected glibc floor (e.g. manylinux_2_35_x86_64)
    plat_auto = _manylinux_plat(python; manylinux=true)
    if Sys.islinux()
        @test startswith(plat_auto, "manylinux_")
        @test endswith(plat_auto, arch)           # same arch as raw tag
        # version part is "2_XX" — check it's at least 2_17
        parts = split(plat_auto, "_")             # ["manylinux", "2", "XX", arch...]
        @test parts[1] == "manylinux"
        @test parse(Int, parts[2]) == 2
        @test parse(Int, parts[3]) >= 17
    end

    # On macOS / other: manylinux argument is a no-op
    if !Sys.islinux()
        @test plat_auto == plat_raw
        @test plat_pinned == plat_raw
    end

    # ── _wheel_tag ───────────────────────────────────────────────────
    tag = _wheel_tag(python)
    @test startswith(tag, "cp")
    parts = split(tag, "-")
    @test length(parts) == 3      # "cpXY-cpXY-<plat>"
    if Sys.islinux()
        @test startswith(parts[3], "manylinux_")
    end

    tag_raw = _wheel_tag(python; manylinux=false)
    if Sys.islinux()
        @test !occursin("manylinux", tag_raw)
        @test occursin("linux_", tag_raw)
    end

    tag_pinned = _wheel_tag(python; manylinux="2.17")
    if Sys.islinux()
        @test occursin("manylinux_2_17_", tag_pinned)
    end

    # ── _wheel_tag_abi3 ──────────────────────────────────────────────
    tag_abi3 = _wheel_tag_abi3(python)
    @test startswith(tag_abi3, "cp311-abi3-")
    if Sys.islinux()
        @test occursin("manylinux_", tag_abi3)
    end

    tag_abi3_raw = _wheel_tag_abi3(python; manylinux=false)
    @test startswith(tag_abi3_raw, "cp311-abi3-")
    if Sys.islinux()
        @test !occursin("manylinux_", tag_abi3_raw)
    end

    tag_abi3_pinned = _wheel_tag_abi3(python; manylinux="2.17")
    if Sys.islinux()
        @test occursin("manylinux_2_17_", tag_abi3_pinned)
    end
end

@testset "startup_benchmark utility (item 11)" begin
    python = get(ENV, "PYTHON3", "python3")

    # Use a trivial .py module as a stand-in for a real .so — the timing
    # mechanism (subprocess + stdout parsing) is identical.
    td = mktempdir()
    try
        dummy = joinpath(td, "dummy_ext.py")
        write(dummy, "def add(a, b): return a + b\n")

        # Import-only mode
        r = startup_benchmark(dummy; n=3, python)
        @test r.n == 3
        @test r.import_ms_median !== nothing
        @test r.import_ms_median >= 0.0
        @test r.import_ms_min <= r.import_ms_median <= r.import_ms_max
        @test r.call_ms_median === nothing     # not requested
        @test r.call_ms_min    === nothing
        @test r.call_ms_max    === nothing

        # Import + first-call mode
        r2 = startup_benchmark(dummy; call_expr="mod.add(1, 2)", n=3, python)
        @test r2.n == 3
        @test r2.call_ms_median !== nothing
        @test r2.call_ms_median >= 0.0
        @test r2.call_ms_min <= r2.call_ms_median <= r2.call_ms_max

        # mod_name override: works even when the filename is ambiguous
        r3 = startup_benchmark(dummy; mod_name="dummy_ext", n=1, python)
        @test r3.n == 1
        @test r3.import_ms_median !== nothing

        # Error on n < 1
        @test_throws ErrorException startup_benchmark(dummy; n=0, python)
    finally
        rm(td; recursive=true)
    end
end

# ── pt CLI app (item 16) ──────────────────────────────────────────────────────

# Include pt.jl in an isolated module so julia_main() doesn't collide with Main.
module _PtAppTest
    include(joinpath(@__DIR__, "..", "app", "pt.jl"))
end

@testset "pt CLI: argument parser (_parse_flags)" begin
    pf = _PtAppTest._parse_flags

    pos, flags = pf(["file.jl", "--outdir=./out", "--verbose"])
    @test pos == ["file.jl"]
    @test flags["outdir"] == "./out"
    @test flags["verbose"] == "true"

    pos, flags = pf(["--trim=unsafe", "--abi3", "src.jl", "--mod-name=mymod"])
    @test pos == ["src.jl"]
    @test flags["trim"] == "unsafe"
    @test flags["abi3"] == "true"
    @test flags["mod-name"] == "mymod"

    pos, flags = pf(String[])
    @test isempty(pos)
    @test isempty(flags)

    pos, flags = pf(["-h"])
    @test isempty(pos)
    @test flags["h"] == "true"

    pos, flags = pf(["--manylinux=2.17"])
    @test flags["manylinux"] == "2.17"

    pos, flags = pf(["--manylinux=false"])
    @test flags["manylinux"] == "false"

    # Multiple positionals
    pos, flags = pf(["a.jl", "b.jl", "--verbose"])
    @test pos == ["a.jl", "b.jl"]
    @test flags["verbose"] == "true"
end

@testset "pt CLI: _bool_flag" begin
    bf = _PtAppTest._bool_flag
    @test  bf(Dict("abi3" => "true"),  "abi3")
    @test !bf(Dict("abi3" => "true"),  "slim")
    @test !bf(Dict("verbose" => "false"), "verbose")
    @test  bf(Dict("slim" => "true"),  "slim")
end

@testset "pt CLI: command dispatch (no-arg / help returns)" begin
    # No file → returns 1 (usage error)
    @test _PtAppTest._cmd_build(String[]) == 1
    @test _PtAppTest._cmd_wheel(String[]) == 1
    @test _PtAppTest._cmd_bench(String[]) == 1

    # File + --help → returns 0 (help was explicitly requested alongside a file)
    @test _PtAppTest._cmd_build(["myfile.jl", "--help"]) == 0
    @test _PtAppTest._cmd_wheel(["myfile.jl", "--help"]) == 0
    @test _PtAppTest._cmd_bench(["ext.so",   "--help"]) == 0

    # -h short flag works the same as --help
    @test _PtAppTest._cmd_build(["myfile.jl", "-h"]) == 0
end

@testset "pt CLI: _USAGE and _PT_CLI_VERSION constants" begin
    @test !isempty(_PtAppTest._PT_CLI_VERSION)
    @test occursin("build",   _PtAppTest._USAGE)
    @test occursin("wheel",   _PtAppTest._USAGE)
    @test occursin("bench",   _PtAppTest._USAGE)
    @test occursin("version", _PtAppTest._USAGE)
end
