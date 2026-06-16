using Test
using ParselTongue

# End-to-end: build the fixture extension with juliac --trim=safe, then import and
# call it from a *separate* Python process (a second libjulia can't load into this
# Julia test process). A successful --trim=safe build is itself the trim-cleanliness
# proof — juliac errors on any dynamic dispatch in an exported path.

# On Windows, Python 3.8+ ignores PATH for extension DLL resolution; every
# required directory must be registered via os.add_dll_directory.
# Sys.BINDIR holds libjulia.dll, libjulia-internal.dll, libjulia-codegen.dll,
# AND the MinGW-w64 runtime DLLs that Julia ships (libgcc_s_seh-1.dll,
# libstdc++-6.dll, libwinpthread-1.dll).  We must NOT add a separate MinGW
# bin/ because different DLL versions conflict and break Julia's codegen init.
# lib/julia contains additional support DLLs (OpenBLAS, etc.).
function _win_dll_preamble()
    Sys.iswindows() || return ""
    # Sys.BINDIR holds libjulia*.dll plus Julia's bundled MinGW-w64 runtime
    # DLLs. lib/julia has OpenBLAS and other support DLLs.
    # Do NOT add a system MinGW bin/ — version conflicts break libjulia-codegen.
    julia_prefix = dirname(Sys.BINDIR)
    dirs = filter(isdir, String[Sys.BINDIR,
                                joinpath(julia_prefix, "lib", "julia")])
    calls = join(["os.add_dll_directory($(repr(d)))" for d in unique(dirs)], "; ")
    "import os; $calls\n"
end

function _py_run(script::AbstractString)
    py = Sys.which("python3")
    buf = IOBuffer()
    try
        run(pipeline(`$py -c $script`, stdout=buf, stderr=buf))
    catch e
        out = String(take!(buf))
        error("Python process failed:\n$out\nCaused by: $e")
    end
    String(take!(buf))
end

function _have_tools()
    Sys.which("python3") !== nothing || return false
    (Sys.which("cc") !== nothing || Sys.which("gcc") !== nothing) || return false
    bs = joinpath(Sys.BINDIR, Base.DATAROOTDIR, "julia", "juliac", "juliac-buildscript.jl")
    isfile(bs)
end

@testset "integration: build + import (scalars, strings, arrays)" begin
    if !_have_tools()
        @info "skipping integration test (need python3, a C compiler, and juliac)"
        @test_skip true
    elseif Sys.iswindows()
        # On Windows, build_extension produces a bare .pyd with no __init__.py.
        # DLL resolution for libjulia*.dll and the MinGW runtime requires either a
        # wheel (which ships __init__.py with os.add_dll_directory calls) or a
        # pre-configured Python environment. The integration test therefore only
        # verifies that the build succeeds; the Python import is wheel-only on Windows.
        fixture = joinpath(@__DIR__, "fixtures", "feature.jl")
        outdir  = mktempdir()
        so = build_extension(fixture; outdir=outdir)
        @test isfile(so)
        @info "Windows: build succeeded (Python import skipped for bare extension — use build_wheel)"
    else
        fixture = joinpath(@__DIR__, "fixtures", "feature.jl")
        outdir = mktempdir()
        so = build_extension(fixture; outdir=outdir)        # trim=safe by default
        @test isfile(so)

        # Drive the extension from a clean subprocess and report pass/fail.
        script = """
        $(_win_dll_preamble())import sys, array, cmath
        sys.path.insert(0, $(repr(outdir)))
        import feature
        assert feature.add(40, 2) == 42
        assert feature.is_even(10) is True and feature.is_even(7) is False
        assert feature.greet("World") == "Hello, World!"
        assert feature.conj1(3 + 4j) == 3 - 4j
        assert feature.sum_f64(array.array("d", [1.0, 2.0, 3.0, 4.0])) == 10.0
        assert feature.minmax(array.array("d", [3.0, 1.0, 5.0])) == (1.0, 5.0)
        x = array.array("d", [1.0, 2.0, 3.0])
        assert feature.scale(x, 10.0) is None and list(x) == [10.0, 20.0, 30.0]  # in-place + void
        try:
            import numpy as np
            A = np.array([[1.0, 2.0, 3.0], [4.0, 5.0, 6.0]])      # 2x3 C-order
            assert np.allclose(feature.rowsums(A), [6.0, 15.0])   # logical view: NumPy shape
            assert list(feature.dims(A)) == [3, 2]                # dense: transposed for C-order
        except ImportError:
            pass
        # Julia errors must surface as Python RuntimeError (not crashes)
        try:
            feature.boom()
            assert False, "expected RuntimeError from boom()"
        except RuntimeError as exc:
            assert "boom!" in str(exc), f"wrong message: {exc}"
        try:
            feature.safe_div(1.0, 0.0)
            assert False, "expected RuntimeError from safe_div"
        except RuntimeError as exc:
            assert "division by zero" in str(exc), f"wrong message: {exc}"
        assert feature.safe_div(10.0, 2.0) == 5.0  # success path still works
        # GIL is released during Julia compute: two threads should overlap
        import threading, time
        t0 = time.time()
        results = []
        threads = [threading.Thread(target=lambda: results.append(feature.sleep_ms(100))) for _ in range(2)]
        for t in threads: t.start()
        for t in threads: t.join()
        elapsed = time.time() - t0
        assert elapsed < 0.40, f"GIL not released: elapsed {elapsed:.2f}s (expected < 0.40s)"
        assert results.count(100) == 2
        # Zero-copy array returns: base chain must not go through a bytearray
        try:
            import numpy as np
            A = np.array([[1.0, 2.0, 3.0], [4.0, 5.0, 6.0]])
            out = feature.rowsums(A)
            bases = []
            b = out
            while hasattr(b, "base") and b.base is not None:
                b = b.base; bases.append(b)
            assert not any(isinstance(x, bytearray) for x in bases), "array return went through bytearray (not zero-copy)"
        except ImportError:
            pass
        # Keyword/default arguments (item 5)
        assert feature.power(3.0) == 9.0,            "power(3.0) default exponent"
        assert feature.power(3.0, exponent=3.0) == 27.0, "power(3.0, exponent=3.0)"
        assert feature.power(base=2.0, exponent=10.0) == 1024.0, "power all kwargs"
        assert feature.clamp_val(0.5) == 0.5,        "clamp_val in [0,1]"
        assert feature.clamp_val(-1.0) == 0.0,       "clamp_val below lo"
        assert feature.clamp_val(2.0) == 1.0,        "clamp_val above hi"
        assert feature.clamp_val(0.5, lo=0.3, hi=0.7) == 0.5, "clamp_val custom range"
        # Vector{String} <-> list[str] (item 8)
        assert feature.words("hello world") == ["hello", "world"], "words() return"
        assert feature.join_words(["a", "b", "c"]) == "a b c", "join_words() arg"
        assert feature.join_words([]) == "", "join_words([]) empty"
        # NamedTuple <-> dict return (item 8)
        import array as _array
        d = feature.describe(_array.array("d", [1.0, 3.0, 2.0]))
        assert isinstance(d, dict), f"describe() must return dict, got {type(d)}"
        assert d["min"] == 1.0 and d["max"] == 3.0 and d["n"] == 3, f"wrong describe: {d}"
        # Opaque handle types (item 12): real Python classes (isinstance, repr)
        p = feature.make_point(3.0, 4.0)
        assert isinstance(p, feature.Pt2D), f"expected Pt2D instance, got {type(p)}"
        assert type(p).__name__ == "Pt2D", f"type name: {type(p).__name__}"
        assert repr(p) == "<Pt2D: x=3.0, y=4.0>", f"repr: {repr(p)}"
        assert feature.point_x(p) == 3.0, "point_x"
        assert feature.point_y(p) == 4.0, "point_y"
        assert feature.point_norm(p) == 5.0, "point_norm 3-4-5"
        p2 = feature.point_scale(p, 2.0)
        assert isinstance(p2, feature.Pt2D), "scaled result is Pt2D"
        assert feature.point_x(p2) == 6.0 and feature.point_y(p2) == 8.0, "point_scale"
        del p, p2   # tp_dealloc calls free()
        # Python callables as arguments (item F)
        assert feature.apply(lambda x: x * 2.0, 3.0) == 6.0,    "apply: identity"
        assert feature.apply(abs, -5.0) == 5.0,                  "apply: builtin"
        root = feature.bisect(lambda x: x**2 - 2.0, 1.0, 2.0)
        assert abs(root - 2.0**0.5) < 1e-10,                     "bisect: sqrt(2)"
        print("FEATURE_OK")
        """
        out = _py_run(script)
        @test occursin("FEATURE_OK", out)

        # Measure first-import and first-call latency (informational — no assertion).
        r = startup_benchmark(so; call_expr="mod.add(1, 2)", n=3)
        @info "startup: import $(round(r.import_ms_median; digits=1))ms " *
              "(min=$(round(r.import_ms_min; digits=1)) max=$(round(r.import_ms_max; digits=1))), " *
              "first_call $(round(r.call_ms_median; digits=3))ms"
    end   # else (non-Windows)
end

@testset "build_extension input validation" begin
    @test_throws ErrorException build_extension(tempname() * ".jl")   # missing file
    badmod = tempname() * ".jl"
    write(badmod, "x = 1\n")                                          # no @pyfunc
    @test_throws ErrorException build_extension(badmod)
end

@testset "integration: abi3 stable-ABI shim (item 2)" begin
    if !_have_tools()
        @info "skipping abi3 integration test (need python3, a C compiler, and juliac)"
        @test_skip true
    elseif Sys.iswindows()
        fixture = joinpath(@__DIR__, "fixtures", "feature.jl")
        outdir  = mktempdir()
        so = build_extension(fixture; outdir=outdir, abi3=true)
        @test isfile(so)
        @test occursin("abi3", basename(so))
        @info "Windows: abi3 build succeeded (Python import skipped — use build_wheel)"
    else
        fixture = joinpath(@__DIR__, "fixtures", "feature.jl")
        outdir = mktempdir()
        so = build_extension(fixture; outdir=outdir, abi3=true)
        @test isfile(so)
        @test occursin("abi3", basename(so))

        script = """
        import sys
        sys.path.insert(0, $(repr(outdir)))
        import feature
        assert feature.add(40, 2) == 42,         "add"
        assert feature.greet("World") == "Hello, World!", "greet"
        print("ABI3_OK")
        """
        out = _py_run(script)
        @test occursin("ABI3_OK", out)
    end
end
