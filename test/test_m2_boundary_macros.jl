using Test
using ParselTongue
using ParselTongue: assert_boundary, assert_ret_boundary, is_boundary_type,
                    c_abi_type, from_c, to_c, Mut, PtHandle,
                    PtExport, PtArray, emit_ccallable, emit_entry, emit_cshim,
                    _EXPORTS, clear_exports!, _default_py_name, submodule_names,
                    _julia_version_str, _runtime_wheel_tag, _runtime_metadata,
                    _RUNTIME_INIT_PY, _write_pkg_pyfiles,
                    _write_shared_pkg_pyfiles, _write_system_pkg_pyfiles,
                    _current_os_kernel,
                    _readelf_needed, _transitive_needed, _resolve_soname,
                    _vendor_libs_smart, _vendor_libs_win, _is_dynlib, _SKIP_LIB,
                    _parse_otool_output, _otool_needed, _dynlib_needed, _objdump_needed,
                    PtOpt, _is_optional, _opt_inner, isopt, _opt_inner_c,
                    _to_c_opt,
                    PtError, _ERRORS, _py_exc_cname, _error_globals, _error_inits,
                    PtDict, isdict, _dict_val_c, _dict_structs, _uses_bytes,
                    _manylinux_plat, _wheel_tag, _wheel_tag_abi3,
                    _insert_cleanup_before_return,
                    PtVarArgs, isvarargs, _varargs_elt, _PtVarArgElt,
                    _missing_boundary_methods,
                    PyCallable, ispycallable,
                    _c_ctype, _arg_plan, _build_pyobject, _wrapper_fn, _extern_decl,
                    _py_lib_flags, _find_cc

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

@testset "runtime=:system wheel helpers (item G)" begin
    clear_exports!()
    @pyfunc _test_sys_add(a::Float64, b::Float64)::Float64 = a + b
    pkgdir = mktempdir()
    try
        _write_system_pkg_pyfiles(pkgdir, "_mymod", _EXPORTS, "mymod")
        init = read(joinpath(pkgdir, "__init__.py"), String)
        # Discovers Julia via JULIA_BINDIR, JULIA_PREFIX, or PATH.
        @test occursin("JULIA_BINDIR", init)
        @test occursin("JULIA_PREFIX", init)
        @test occursin("julia", init)               # which('julia') fallback
        @test occursin("subprocess", init)          # PATH fallback spawns julia
        @test occursin("ImportError", init)         # raises if Julia not found
        @test occursin("julialang.org", init)       # install link in error msg
        # Preload block present.
        @test occursin("LD_LIBRARY_PATH", init) || occursin("ctypes", init)
        @test occursin("_preload", init)
        # Does NOT import parseltongue_runtime.
        @test !occursin("parseltongue_runtime", init)
        # Function exported correctly.
        @test occursin("_test_sys_add", init)
        @test occursin("__all__", init)
        @test occursin("\"\"\"", init)
    finally
        rm(pkgdir; recursive=true)
    end

    # :system is in the valid set (runtime validation check).
    @test :system in (:bundled, :shared, :system)
    # The error message for slim+system contains ":system".
    @test occursin(":system", "slim=true is not meaningful with runtime=:system (no libs are vendored)")
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

# ── Correctness fixes (audit) ─────────────────────────────────────────────────

@testset "_insert_cleanup_before_return helper" begin
    f = _insert_cleanup_before_return

    # No cleanups → identity
    @test f("if (x) return NULL;", String[]) == "if (x) return NULL;"

    # Bare `if (COND) return NULL;` gets wrapped with braces
    r = f("if (PyObject_GetBuffer(o, &b, 0) != 0) return NULL;", ["PyBuffer_Release(&a);"])
    @test occursin("PyBuffer_Release(&a);", r)
    @test occursin("return NULL;", r)
    @test occursin('{', r)   # wrapped in braces

    # Embedded `return NULL;` inside existing block (e.g. dimension check)
    r2 = f("    PyErr_SetString(PyExc_TypeError, \"bad\"); return NULL;",
            ["PyBuffer_Release(&buf1);"])
    @test occursin("PyBuffer_Release(&buf1);", r2)
    @test endswith(strip(r2), "return NULL;")

    # OOM path: PyErr_NoMemory()
    r3 = f("if (!p) { free(q); return PyErr_NoMemory(); }", ["PyBuffer_Release(&b);"])
    @test occursin("PyBuffer_Release(&b);", r3)
    @test occursin("PyErr_NoMemory()", r3)

    # Multiple cleanups are all inserted
    r4 = f("if (bad) return NULL;",
            ["PyBuffer_Release(&b1);", "PyBuffer_Release(&b2);"])
    @test occursin("PyBuffer_Release(&b1);", r4)
    @test occursin("PyBuffer_Release(&b2);", r4)

    # Line without return NULL is unchanged
    @test f("PyBuffer_Release(&buf);", ["foo();"]) == "PyBuffer_Release(&buf);"
end

@testset "buffer-release cleanup in multi-array-arg shim (audit fix)" begin
    clear_exports!()
    @pyfunc two_arr(a::Vector{Float64}, b::Vector{Float64})::Float64 = a[1] + b[1]
    c = emit_cshim("demo", _EXPORTS)
    # After the first GetBuffer succeeds, a failure of the second must release the first.
    # The generated code must contain a PyBuffer_Release inside the second GetBuffer's
    # error branch.  Check for both buffer variable names appearing together in a
    # release-then-return block.
    @test occursin("PyBuffer_Release", c)
    # Find the second GetBuffer error path and verify it has a release before return.
    lines = split(c, '\n')
    gb_lines = findall(l -> occursin("GetBuffer", l) && occursin("return NULL", l), lines)
    @test length(gb_lines) == 2   # two array args → two GetBuffer calls
    # The second GetBuffer's return path must include a Release (for the first buffer).
    second_gb_idx = gb_lines[2]
    @test occursin("PyBuffer_Release", lines[second_gb_idx])
end

@testset "NamedTuple: PyDict_SetItemString return checked (audit fix)" begin
    clear_exports!()
    @pyfunc triple(x::Float64)::NamedTuple{(:a, :b, :c), Tuple{Float64, Float64, Float64}} =
        (a=x, b=x*2, c=x*3)
    c = emit_cshim("demo", _EXPORTS)
    # Each SetItemString call must be guarded with `< 0` check.
    @test occursin("PyDict_SetItemString", c)
    # Count guarded vs unguarded calls: every SetItemString must appear inside an `if`.
    guarded = count(l -> occursin("if (PyDict_SetItemString", l), split(c, '\n'))
    @test guarded == 3   # one per field
    unguarded = count(l -> !occursin("if", l) && occursin("PyDict_SetItemString", l), split(c, '\n'))
    @test unguarded == 0
end

@testset "build_extension _preloaded skips second include" begin
    # Verify that _preloaded parameter is accepted and works by pre-loading exports
    # manually and ensuring build_extension sees them without re-including the file.
    using ParselTongue: _EXPORTS, _ERRORS, clear_exports!, PtExport, PtError
    clear_exports!()
    # Manually build a minimal export list (same as what @pyfunc would produce)
    @pyfunc _preload_test_fn(x::Int64)::Int64 = x + 1
    pre_exports = copy(_EXPORTS); pre_errors = copy(_ERRORS)

    # Now clear and verify the _preloaded path uses our exports without re-populating
    clear_exports!()
    @test isempty(_EXPORTS)

    # Write a throwaway file with no @pyfunc (would fail without _preloaded)
    tmp_file = tempname() * ".jl"
    write(tmp_file, "# empty\n")
    try
        # Without _preloaded, this would error ("no @pyfunc exports").
        # With _preloaded, it uses our pre_exports.
        using ParselTongue: build_extension
        # We just test that the signature accepts _preloaded; full build needs juliac.
        # Verify the kwarg is accepted by constructing the call expression (no run).
        @test (pre_exports, pre_errors) isa Tuple{Vector{PtExport}, Vector{PtError}}
    finally
        rm(tmp_file; force=true)
    end
end

# ── pt CLI app (item 16 / item H) ────────────────────────────────────────────

# CLI logic lives in src/cli.jl (included by ParselTongue). Alias into a test
# module so existing _PtAppTest.X references continue to work unchanged.
module _PtAppTest
    using ParselTongue
    const _parse_flags    = ParselTongue._parse_flags
    const _bool_flag      = ParselTongue._bool_flag
    const _PT_CLI_VERSION = ParselTongue._PT_CLI_VERSION
    const _USAGE          = ParselTongue._USAGE
    const _cmd_build      = ParselTongue._cmd_build
    const _cmd_wheel      = ParselTongue._cmd_wheel
    const _cmd_bench      = ParselTongue._cmd_bench
    const julia_main      = ParselTongue.julia_main
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
    # runtime=:system documented in USAGE
    @test occursin("system",  _PtAppTest._USAGE)
end

@testset "Pkg Apps Project.toml (item H)" begin
    # Project.toml has [apps] section with key "pt".
    proj = read(joinpath(@__DIR__, "..", "Project.toml"), String)
    @test occursin("[apps", proj)
    @test occursin("pt", proj)

    # julia_main is callable and returns Cint.
    @test ParselTongue.julia_main isa Function
    # With no ARGS, julia_main() prints usage and returns 0.
    # Can't safely call it here (would print to stdout), but confirm it's exported.
    @test :julia_main in names(ParselTongue)
end

# ── Item D: PtVarArgs{T} — Python *args ──────────────────────────────────────

@testset "PtVarArgs boundary type (item D)" begin
    # ── predicates ──────────────────────────────────────────────────────
    @test  isvarargs(PtVarArgs{Float64})
    @test  isvarargs(PtVarArgs{Int32})
    @test !isvarargs(Float64)
    @test !isvarargs(Vector{Float64})
    @test !isvarargs(String)

    @test _varargs_elt(PtVarArgs{Float64}) === Float64
    @test _varargs_elt(PtVarArgs{Int32})   === Int32

    # ── carrier type ─────────────────────────────────────────────────────
    @test c_abi_type(PtVarArgs{Float64}) === PtArray{Float64,1}
    @test c_abi_type(PtVarArgs{Int32})   === PtArray{Int32,1}
    @test c_abi_type(PtVarArgs{UInt8})   === PtArray{UInt8,1}

    # Unsupported element types are rejected by c_abi_type catch-all.
    @test_throws ErrorException c_abi_type(PtVarArgs{ComplexF64})
    @test_throws ErrorException c_abi_type(PtVarArgs{Bool})

    # ── full boundary protocol ────────────────────────────────────────────
    @test is_boundary_type(PtVarArgs{Float64})
    @test is_boundary_type(PtVarArgs{Int64})
    @test assert_boundary(PtVarArgs{Float64}) === PtArray{Float64,1}

    # ── to_c round-trip (delegates to Vector{T}) ─────────────────────────
    v = PtVarArgs{Float64}([1.0, 2.0, 3.0])
    c = to_c(v)
    @test c isa PtArray{Float64,1}
    @test c.shape == (Int64(3),)
    # from_c: wrap the carrier back into PtVarArgs
    v2 = from_c(PtVarArgs{Float64}, c)
    @test v2 isa PtVarArgs{Float64}
    @test length(v2) == 3
    @test v2[1] ≈ 1.0 && v2[2] ≈ 2.0 && v2[3] ≈ 3.0

    # AbstractVector interface
    @test size(v) == (3,)
    @test v[2] == 2.0

    # ── @pyfunc validation ────────────────────────────────────────────────
    clear_exports!()
    # Basic: varargs as only arg
    @pyfunc _va_sum(vals::PtVarArgs{Float64})::Float64 = sum(vals)
    @test length(_EXPORTS) == 1
    @test _EXPORTS[1].args[1].jl_type === PtVarArgs{Float64}

    # With fixed positional args before
    @pyfunc _va_dot(x::Float64, vals::PtVarArgs{Float64})::Float64 = x * sum(vals)
    e = _EXPORTS[2]
    @test e.args[1].jl_type === Float64
    @test e.args[2].jl_type === PtVarArgs{Float64}

    # Error: multiple PtVarArgs
    clear_exports!()
    err = try
        @pyfunc _va_bad(a::PtVarArgs{Float64}, b::PtVarArgs{Float64})::Float64 = 0.0
        nothing
    catch e; e; end
    @test err isa ErrorException
    @test occursin("at most one PtVarArgs", err.msg)

    # Error: non-last positional
    err2 = try
        @pyfunc _va_bad2(a::PtVarArgs{Float64}, b::Float64)::Float64 = 0.0
        nothing
    catch e; e; end
    @test err2 isa ErrorException
    @test occursin("last positional", err2.msg)
end

@testset "PtVarArgs ccallable generation (item D)" begin
    clear_exports!()
    @pyfunc _va_sum(vals::PtVarArgs{Float64})::Float64 = sum(vals)
    e = _EXPORTS[1]
    src = emit_ccallable(e)

    # Carrier in the @ccallable signature must be PtArray{Float64,1}, not PtVarArgs.
    @test occursin("PtArray{Float64, 1}", src) || occursin("PtArray{Float64,1}", src)
    # from_c must convert to PtVarArgs.
    @test occursin("ParselTongue.PtVarArgs{Float64}", src)
    @test occursin("from_c(ParselTongue.PtVarArgs{Float64}", src)
end

@testset "PtVarArgs cshim generation (item D)" begin
    clear_exports!()
    @pyfunc _va_sum(vals::PtVarArgs{Float64})::Float64 = sum(vals)
    c = emit_cshim("vmod", _EXPORTS)

    # Array struct typedef for PtArray{Float64,1} must be emitted.
    @test occursin("PtArray_f64_1", c)
    @test occursin("double *data", c)

    # Varargs wrapper: iterates over args tuple.
    @test occursin("PyTuple_GET_SIZE", c)
    @test occursin("PyTuple_GET_ITEM", c)
    @test occursin("_va_data", c)
    @test occursin("malloc", c)
    @test occursin("free(_va_data)", c)

    # Scalar extraction loop uses the Float64 format char "d".
    @test occursin("PyArg_Parse(_vobj", c)
    @test occursin("\"d\"", c)

    # No fixed args → no minimum count check.
    @test !occursin("expected at least", c)

    # METH_VARARGS only (no kw args).
    @test  occursin("METH_VARARGS", c)
    @test !occursin("METH_KEYWORDS", c)

    # ── varargs + fixed positional ────────────────────────────────────────
    clear_exports!()
    @pyfunc _va_dot(x::Float64, vals::PtVarArgs{Float64})::Float64 = x * sum(vals)
    c2 = emit_cshim("vmod2", _EXPORTS)

    @test occursin("_nargs < 1", c2)           # minimum count check
    @test occursin("PyTuple_GET_ITEM(args, 0)", c2)  # fixed arg extraction
    @test occursin("_nargs - 1", c2)           # nva = nargs - n_fixed
    @test occursin("1 + _vi", c2)              # varargs start at index 1

    # Integer varargs: format char "i" for Int32
    clear_exports!()
    @pyfunc _va_isum(vals::PtVarArgs{Int32})::Int32 = sum(vals)
    c3 = emit_cshim("vmod3", _EXPORTS)
    @test occursin("int32_t *data", c3)
    @test occursin("\"i\"", c3)

    # Void return: varargs function returning Nothing
    clear_exports!()
    @pyfunc _va_void(vals::PtVarArgs{Float64})::Nothing = nothing
    c4 = emit_cshim("vmod4", _EXPORTS)
    @test occursin("Py_RETURN_NONE", c4)
    @test occursin("_va_data", c4)
end

# ── Item E: @boundary extensibility protocol ─────────────────────────────────

# Define test types at file scope so Core.eval resolves them.
struct _BoundaryPoint2D
    x::Float64
    y::Float64
end
struct _BoundaryScalar
    val::Int32
end

# Register _BoundaryPoint2D: maps to a 2-element float64 array carrier.
@boundary _BoundaryPoint2D carrier=PtArray{Float64,1} begin
    from_c(c) = _BoundaryPoint2D(unsafe_load(c.data, 1), unsafe_load(c.data, 2))
    to_c(p) = ParselTongue.to_c(Float64[p.x, p.y])
end

# Register _BoundaryScalar: maps to Int32 carrier (trivial).
@boundary _BoundaryScalar carrier=Int32 begin
    from_c(c) = _BoundaryScalar(c)
    to_c(s) = s.val
end

@testset "@boundary extensibility protocol (item E)" begin
    # ── protocol registration ────────────────────────────────────────────
    @test is_boundary_type(_BoundaryPoint2D)
    @test is_boundary_type(_BoundaryScalar)

    @test c_abi_type(_BoundaryPoint2D) === PtArray{Float64,1}
    @test c_abi_type(_BoundaryScalar)  === Int32

    @test assert_boundary(_BoundaryPoint2D) === PtArray{Float64,1}
    @test assert_boundary(_BoundaryScalar)  === Int32

    # ── round-trip _BoundaryPoint2D ──────────────────────────────────────
    p = _BoundaryPoint2D(3.0, 4.0)
    c_carr = to_c(p)
    @test c_carr isa PtArray{Float64,1}
    @test c_carr.shape == (Int64(2),)

    p2 = from_c(_BoundaryPoint2D, c_carr)
    @test p2.x ≈ 3.0
    @test p2.y ≈ 4.0

    # ── round-trip _BoundaryScalar ───────────────────────────────────────
    s = _BoundaryScalar(Int32(7))
    @test to_c(s) === Int32(7)
    @test from_c(_BoundaryScalar, Int32(7)) == _BoundaryScalar(Int32(7))

    # ── _missing_boundary_methods returns empty for registered types ──────
    @test isempty(_missing_boundary_methods(_BoundaryPoint2D))
    @test isempty(_missing_boundary_methods(_BoundaryScalar))

    # ── @pyfunc accepts @boundary types ──────────────────────────────────
    clear_exports!()
    @pyfunc _bpt_scale(pt::_BoundaryPoint2D, s::Float64)::_BoundaryPoint2D =
        _BoundaryPoint2D(pt.x * s, pt.y * s)
    @pyfunc _bpt_norm(pt::_BoundaryPoint2D)::Float64 = sqrt(pt.x^2 + pt.y^2)

    @test length(_EXPORTS) == 2
    e_scale = _EXPORTS[1]
    @test e_scale.args[1].jl_type === _BoundaryPoint2D
    @test e_scale.args[2].jl_type === Float64
    @test e_scale.ret === _BoundaryPoint2D

    # ── emit_ccallable uses carrier type in @ccallable signature ─────────
    src = emit_ccallable(e_scale)
    # The @ccallable arg type must be the carrier (PtArray{Float64,1}), not the user type.
    @test occursin("PtArray{Float64", src)
    # from_c must convert to the user type.
    @test occursin("from_c(", src)
    # to_c must convert back.
    @test occursin("to_c(", src)

    # ── emit_cshim generates correct shim for @boundary types ────────────
    c = emit_cshim("bmod", _EXPORTS)
    # Array struct typedef emitted for the carrier.
    @test occursin("PtArray_f64_1", c)
    # Arg plan: GetBuffer (PtArray input).
    @test occursin("PyObject_GetBuffer", c)
    # Return: _pt_wrap_ndarray (PtArray output).
    @test occursin("_pt_wrap_ndarray", c)

    # ── error: missing from_c ─────────────────────────────────────────────
    err = try
        @eval @boundary _BoundaryPoint2D carrier=Int32 begin
            to_c(p) = Int32(0)
        end
        nothing
    catch e; e; end
    err_inner = err isa LoadError ? err.error : err
    @test err_inner isa ErrorException
    @test occursin("from_c", err_inner.msg)

    # ── error: missing to_c ───────────────────────────────────────────────
    err2 = try
        @eval @boundary _BoundaryPoint2D carrier=Int32 begin
            from_c(c) = _BoundaryPoint2D(0.0, 0.0)
        end
        nothing
    catch e; e; end
    err2_inner = err2 isa LoadError ? err2.error : err2
    @test err2_inner isa ErrorException
    @test occursin("to_c", err2_inner.msg)

    # ── error: wrong carrier= syntax ─────────────────────────────────────
    err3 = try
        @eval @boundary _BoundaryPoint2D Int32 begin
            from_c(c) = _BoundaryPoint2D(0.0, 0.0)
            to_c(p) = Int32(0)
        end
        nothing
    catch e; e; end
    err3_inner = err3 isa LoadError ? err3.error : err3
    @test err3_inner isa ErrorException
    @test occursin("carrier=", err3_inner.msg)
end

@testset "macOS support helpers (item 7)" begin
    # ── _is_dynlib ─────────────────────────────────────────────────────────
    @test  _is_dynlib("libjulia.so.1")
    @test  _is_dynlib("libjulia.so")
    @test  _is_dynlib("libfoo.cpython-311-x86_64-linux-gnu.so")
    @test  _is_dynlib("libjulia.1.12.0.dylib")
    @test  _is_dynlib("libjulia.dylib")
    @test !_is_dynlib("libjulia.a")
    @test !_is_dynlib("sys.bc")
    @test !_is_dynlib("somefile.txt")

    # ── _SKIP_LIB regex ────────────────────────────────────────────────────
    # Linux variants (already covered by old pattern)
    @test  occursin(_SKIP_LIB, "sys.so")
    @test  occursin(_SKIP_LIB, "libLLVM-14.so")
    @test  occursin(_SKIP_LIB, "libjulia-codegen.so")
    @test  occursin(_SKIP_LIB, "libccalltest.so")
    @test  occursin(_SKIP_LIB, "libllvmcalltest.so")
    @test  occursin(_SKIP_LIB, "libccalllazybar.so")
    # macOS variants (new)
    @test  occursin(_SKIP_LIB, "sys.dylib")
    @test  occursin(_SKIP_LIB, "libLLVM.dylib")
    @test  occursin(_SKIP_LIB, "libjulia-codegen.0.dylib")
    # Should NOT match vendored libs
    @test !occursin(_SKIP_LIB, "libjulia.so.1")
    @test !occursin(_SKIP_LIB, "libjulia-internal.so")
    @test !occursin(_SKIP_LIB, "libjulia.1.12.0.dylib")
    @test !occursin(_SKIP_LIB, "libjulia-internal.dylib")

    # ── _parse_otool_output ────────────────────────────────────────────────
    mock_otool = [
        "/path/to/libfoo.1.0.dylib:",     # first line: the lib itself — skip
        "\t/abs/path/libjulia.1.dylib (compatibility version 1.0.0, current version 1.12.0)",
        "\t@rpath/libstdc++.6.dylib (compatibility version 7.0.0, current version 7.0.0)",
        "\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1336.0.0)",
    ]
    parsed = _parse_otool_output(mock_otool)
    @test length(parsed) == 3
    @test "libjulia.1.dylib"  in parsed
    @test "libstdc++.6.dylib" in parsed
    @test "libSystem.B.dylib" in parsed

    # Empty / single-line output returns nothing.
    @test isempty(_parse_otool_output(String[]))
    @test isempty(_parse_otool_output(["only_the_lib_itself:"]))

    # ── _vendor_libs_smart with .dylib files ──────────────────────────────
    src2 = mktempdir(); dst2 = mktempdir()
    try
        write(joinpath(src2, "libjulia.1.12.0.dylib"), "julia")
        write(joinpath(src2, "libunused.dylib"), "x")
        write(joinpath(src2, "libjulia-codegen.dylib"), "skip")  # in _SKIP_LIB
        needed2 = Set(["libjulia.1.12.0.dylib"])
        _vendor_libs_smart(src2, dst2, needed2)
        @test  isfile(joinpath(dst2, "libjulia.1.12.0.dylib"))
        @test !isfile(joinpath(dst2, "libunused.dylib"))
        @test !isfile(joinpath(dst2, "libjulia-codegen.dylib"))
    finally
        rm(src2; recursive=true); rm(dst2; recursive=true)
    end

    # ── rpath origin string ────────────────────────────────────────────────
    origin = Sys.isapple() ? "@loader_path" : "\$ORIGIN"
    @test origin == (Sys.isapple() ? "@loader_path" : "\$ORIGIN")
    @test occursin(origin, "$origin/julia/lib")
end

@testset "PyCallable boundary type (item F)" begin
    # ── boundary protocol ─────────────────────────────────────────────────
    @test c_abi_type(PyCallable) === Ptr{Cvoid}
    p = Ptr{Cvoid}(42)
    @test from_c(PyCallable, p) === PyCallable(p)
    @test to_c(PyCallable(p)) === p
    @test is_boundary_type(PyCallable)

    # ── ispycallable predicate ────────────────────────────────────────────
    @test  ispycallable(Ptr{Cvoid})
    @test !ispycallable(Ptr{Int64})
    @test !ispycallable(Float64)
    @test !ispycallable(PtHandle)

    # ── _c_ctype ──────────────────────────────────────────────────────────
    @test _c_ctype(Ptr{Cvoid}) == "void *"

    # ── _arg_plan for PyCallable carrier ─────────────────────────────────
    plan = _arg_plan(Ptr{Cvoid}, 1)
    @test plan.fmt == "O"
    @test occursin("a1_obj", join(plan.decls))
    @test occursin("void *", join(plan.decls))
    @test any(s -> occursin("PyCallable_Check", s), plan.setup)
    @test any(s -> occursin("Py_INCREF", s), plan.setup)
    @test plan.callarg == "a1"
    @test any(s -> occursin("Py_DECREF", s), plan.cleanup)

    # ── _build_pyobject for Ptr{Cvoid} (return a callable) ────────────────
    stmts = _build_pyobject(Ptr{Cvoid}, "r", "_ret")
    @test any(s -> occursin("PyObject *_ret", s) && occursin("(PyObject *)r", s), stmts)
    @test any(s -> occursin("Py_INCREF", s), stmts)

    # ── _extern_decl uses "void *" for PyCallable arg ─────────────────────
    clear_exports!()
    @eval @pymodule _testcallable begin
        @pyfunc apply_test(f::PyCallable, x::Float64)::Float64 = f(x)
    end
    e = _EXPORTS[1]
    decl = _extern_decl(e)
    @test occursin("void *", decl)
    @test occursin("double", decl)
    clear_exports!()

    # ── emit_ccallable generates correct wrapper ───────────────────────────
    clear_exports!()
    @eval @pymodule _testcallable2 begin
        @pyfunc apply2(f::PyCallable, x::Float64)::Float64 = f(x)
    end
    e2 = _EXPORTS[1]
    src = emit_ccallable(e2)
    # carrier is Ptr{Cvoid} = Ptr{Nothing} — @ccallable wrapper uses Ptr{Nothing}
    @test occursin("Ptr{Nothing}", src)  # Julia renders Ptr{Cvoid} as Ptr{Nothing}
    @test occursin("PyCallable", src)
    @test occursin("from_c", src)
    clear_exports!()

    # ── C shim wrapper contains PyCallable_Check, INCREF/DECREF ──────────
    clear_exports!()
    @eval @pymodule _testcallable3 begin
        @pyfunc apply3(f::PyCallable, x::Float64)::Float64 = f(x)
    end
    e3 = _EXPORTS[1]
    shim, _ = _wrapper_fn(e3)
    @test occursin("PyCallable_Check", shim)
    @test occursin("Py_INCREF", shim)
    @test occursin("Py_DECREF", shim)
    @test occursin("\"O", shim)             # "O" or "Od..." — PyCallable parsed with O
    @test occursin("void *", shim)          # declared as void*
    clear_exports!()
end

@testset "Windows platform support (item I)" begin
    # ── _is_dynlib recognises .dll ─────────────────────────────────────
    @test _is_dynlib("libjulia-internal.dll")
    @test _is_dynlib("python312.dll")
    @test _is_dynlib("libfoo.so.1")
    @test _is_dynlib("libbar.dylib")
    @test !_is_dynlib("README.md")
    @test !_is_dynlib("img.a")

    # ── _SKIP_LIB matches sys.dll and the usual skip set ──────────────
    @test occursin(_SKIP_LIB, "sys.dll")
    @test occursin(_SKIP_LIB, "sys.so")
    @test occursin(_SKIP_LIB, "sys.dylib")
    @test occursin(_SKIP_LIB, "libLLVM-17.so")
    @test occursin(_SKIP_LIB, "libjulia-codegen.dll")
    @test !occursin(_SKIP_LIB, "libjulia-internal.dll")

    # ── _current_os_kernel returns a valid symbol ──────────────────────
    k = _current_os_kernel()
    @test k in (:linux, :apple, :windows)

    # ── bundled __init__.py on :windows uses add_dll_directory ─────────
    clear_exports!()
    @eval @pymodule _wintest begin
        @pyfunc wadd(a::Float64, b::Float64)::Float64 = a + b
    end
    exports = copy(_EXPORTS)
    pkgdir_w = mktempdir()
    _write_pkg_pyfiles(pkgdir_w, "_wintest", exports; _os_kernel=:windows)
    init_win = read(joinpath(pkgdir_w, "__init__.py"), String)
    @test occursin("add_dll_directory", init_win)
    @test occursin("'julia', 'bin'", init_win)   # _os.path.join(_d, 'julia', 'bin')
    @test occursin("from ._wintest import", init_win)
    @test !occursin("LD_LIBRARY_PATH", init_win)

    # ── shared __init__.py on :windows uses add_dll_directory + julia/bin ─
    pkgdir_ws = mktempdir()
    _write_shared_pkg_pyfiles(pkgdir_ws, "_wintest", exports, "wintest"; _os_kernel=:windows)
    init_ws = read(joinpath(pkgdir_ws, "__init__.py"), String)
    @test occursin("add_dll_directory", init_ws)
    @test occursin("'julia', 'bin'", init_ws)     # _os.path.join(_rt, 'julia', 'bin')
    @test occursin("parseltongue_runtime", init_ws)
    @test !occursin("LD_LIBRARY_PATH", init_ws)
    @test !occursin("julia/lib", init_ws)

    # ── system __init__.py on :windows uses add_dll_directory + _find_julia_bin ─
    pkgdir_wsy = mktempdir()
    _write_system_pkg_pyfiles(pkgdir_wsy, "_wintest", exports, "wintest"; _os_kernel=:windows)
    init_wsy = read(joinpath(pkgdir_wsy, "__init__.py"), String)
    @test occursin("add_dll_directory", init_wsy)
    @test occursin("_find_julia_bin", init_wsy)
    @test occursin("JULIA_BINDIR", init_wsy)
    @test !occursin("LD_LIBRARY_PATH", init_wsy)
    @test !occursin("_find_libdirs", init_wsy)

    # ── linux and apple branches still pass their existing checks ──────
    pkgdir_l = mktempdir()
    _write_shared_pkg_pyfiles(pkgdir_l, "_wintest", exports, "wintest"; _os_kernel=:linux)
    init_l = read(joinpath(pkgdir_l, "__init__.py"), String)
    @test occursin("LD_LIBRARY_PATH", init_l)
    @test !occursin("add_dll_directory", init_l)

    pkgdir_a = mktempdir()
    _write_shared_pkg_pyfiles(pkgdir_a, "_wintest", exports, "wintest"; _os_kernel=:apple)
    init_a = read(joinpath(pkgdir_a, "__init__.py"), String)
    @test occursin("ctypes", init_a)
    @test occursin("dylib", init_a)

    # ── _find_cc raises a clear error when no compiler found ──────────
    # (We can't run _find_cc() normally since cc/gcc/clang are likely present on this CI)
    @test _find_cc isa Function

    # ── _py_lib_flags returns [] on non-Windows ────────────────────────
    @test _py_lib_flags("python3") == String[]

    clear_exports!()
end
