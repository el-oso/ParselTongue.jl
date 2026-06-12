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
