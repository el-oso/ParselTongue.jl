using Test
using ParselTongue

# End-to-end: build the fixture extension with juliac --trim=safe, then import and
# call it from a *separate* Python process (a second libjulia can't load into this
# Julia test process). A successful --trim=safe build is itself the trim-cleanliness
# proof — juliac errors on any dynamic dispatch in an exported path.

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
    else
        fixture = joinpath(@__DIR__, "fixtures", "feature.jl")
        outdir = mktempdir()
        so = build_extension(fixture; outdir=outdir)        # trim=safe by default
        @test isfile(so)

        # Drive the extension from a clean subprocess and report pass/fail.
        script = """
        import sys, array, cmath
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
        assert elapsed < 0.15, f"GIL not released: elapsed {elapsed:.2f}s (expected < 0.15s)"
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
        print("FEATURE_OK")
        """
        out = read(`$(Sys.which("python3")) -c $script`, String)
        @test occursin("FEATURE_OK", out)
    end
end

@testset "build_extension input validation" begin
    @test_throws ErrorException build_extension(tempname() * ".jl")   # missing file
    badmod = tempname() * ".jl"
    write(badmod, "x = 1\n")                                          # no @pyfunc
    @test_throws ErrorException build_extension(badmod)
end
