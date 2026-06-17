using Test
using ParselTongue
using TypeContracts: TrimFailure

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

# Run a Python script in a *clean* environment with only the given env pairs (plus
# HOME/PATH). Used to prove runtime=:system wheels import without LD_LIBRARY_PATH —
# the ctypes RTLD_GLOBAL preload in __init__.py must do the work itself.
function _py_run_env(script::AbstractString, env::Pair...)
    py = Sys.which("python3")
    base = ["HOME" => get(ENV, "HOME", ""), "PATH" => get(ENV, "PATH", "/usr/bin:/bin")]
    buf = IOBuffer()
    try
        run(pipeline(setenv(`$py -c $script`, base..., env...), stdout=buf, stderr=buf))
    catch e
        error("Python process failed:\n$(String(take!(buf)))\nCaused by: $e")
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

        # Drive the extension from a clean subprocess and report pass/fail. The
        # script lives in test/fixtures/feature_script.py (also looped under gdb
        # by the segfault-diag CI job); it locates the extension via FEATURE_DIR.
        script = read(joinpath(@__DIR__, "fixtures", "feature_script.py"), String)
        out = withenv(() -> _py_run(script), "FEATURE_DIR" => outdir)
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

# A --trim=safe failure must surface as an actionable, source-mapped TrimFailure
# (TypeContracts), not juliac's raw verifier dump.
@testset "integration: trim failure → actionable diagnostic" begin
    if !_have_tools()
        @info "skipping trim-diagnostic test (need python3, a C compiler, and juliac)"
        @test_skip true
    else
        fixture = joinpath(@__DIR__, "fixtures", "trimbad.jl")
        err = try
            build_extension(fixture; outdir=mktempdir())
            nothing
        catch e
            e
        end
        @test err isa TrimFailure
        msg = sprint(showerror, err)
        @test occursin("trimbad.jl", msg)          # mapped to the user's source file
        @test occursin("dyn", msg)                 # the offending function
        @test occursin("rejected", msg)            # the readable summary
        @test !occursin("Verifier error #", msg)   # raw juliac dump replaced
    end
end

# Python subclassing + per-instance __dict__ (subclass=true, dict=true): a pure-Python
# subclass adds methods/overrides dunders and sets arbitrary instance attributes; the
# GC type collects reference cycles through the dict. dict=true needs the full API.
@testset "integration: subclass + dict (@pymutable)" begin
    if !_have_tools()
        @info "skipping subclass/dict integration test (need python3, a C compiler, and juliac)"
        @test_skip true
    else
        fixture = joinpath(@__DIR__, "fixtures", "subclassmod.jl")
        # dict=true is incompatible with abi3 (PyTypeObject internals are hidden there).
        @test_throws ErrorException build_extension(fixture; outdir=mktempdir(), abi3=true)

        if Sys.iswindows()
            outdir = mktempdir()
            @test isfile(build_extension(fixture; outdir=outdir))
            @info "Windows: subclass/dict build succeeded (Python import is wheel-only)"
        else
            outdir = mktempdir()
            so = build_extension(fixture; outdir=outdir)
            @test isfile(so)
            script = """
            import sys, gc; sys.path.insert(0, $(repr(outdir)))
            import subclassmod as m
            b = m.Bag("widgets")
            assert isinstance(b, m.Bag)
            assert b.bump() == 1 and b.bump() == 2          # inherited mutation
            assert m.bag_count(b) == 2
            assert repr(b) == "Bag(widgets, n=2)"           # inherited __repr__
            b.tag = "urgent"; assert b.tag == "urgent"      # instance __dict__ (dict=true)
            b.meta = {"k": [1, 2]}; assert b.meta == {"k": [1, 2]}
            assert b.__dict__ == {"tag": "urgent", "meta": {"k": [1, 2]}}, b.__dict__
            class TaggedBag(m.Bag):                         # subclass=true
                def doubled(self): return m.bag_count(self) * 2
                def __repr__(self): return f"Tagged<{m.bag_count(self)}>"
            t = TaggedBag("sub")
            assert isinstance(t, m.Bag) and isinstance(t, TaggedBag)
            t.bump(); t.bump(); t.bump()
            assert t.doubled() == 6, "subclass method over inherited mutation"
            assert repr(t) == "Tagged<3>", "subclass __repr__ override"
            assert m.bag_count(t) == 3, "base C function on subclass instance"
            t.note = [1, 2, 3]; assert t.note == [1, 2, 3]  # subclass instance attribute
            # GC: reference cycles through the instance dict are collectable.
            gc.collect()
            for _ in range(200):
                x = m.Bag("cyc"); x.self_ref = x; x.lst = [x]
            del x
            assert gc.collect() > 0, "GC failed to reclaim reference cycles"
            print("SUBDICT_OK")
            """
            @test occursin("SUBDICT_OK", _py_run(script))
        end
    end
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
        # Windows does not tag extension files with "abi3" in the filename.
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

# Exercise the build_wheel pipeline (distinct from build_extension). Uses
# runtime=:system so no ~100 MB runtime is vendored — fast, and it still drives
# the full include → juliac → shim → __init__.py → zip path plus _preloaded
# threading. This guards against regressions in the wheel-only code path, which
# build_extension tests do not cover.
@testset "integration: build_wheel (system runtime + pyproject)" begin
    if !_have_tools()
        @info "skipping build_wheel integration test (need python3, a C compiler, and juliac)"
        @test_skip true
    else
        fixture = joinpath(@__DIR__, "fixtures", "feature.jl")
        outdir  = mktempdir()
        whl = build_wheel(fixture; runtime=:system, outdir=outdir,
                          version="0.1.0", emit_pyproject=true)
        @test isfile(whl)
        @test endswith(whl, ".whl")
        # pyproject.toml emitted alongside the wheel (item M).
        pyproj = joinpath(outdir, "pyproject.toml")
        @test isfile(pyproj)
        s = read(pyproj, String)
        @test occursin("[project]", s)
        @test occursin("name = \"feature\"", s)
        @test occursin("version = \"0.1.0\"", s)
        # The wheel is a valid zip containing the package __init__.py.
        names = _py_run("""
        import zipfile
        with zipfile.ZipFile($(repr(whl))) as z:
            print("\\n".join(z.namelist()))
        """)
        @test occursin("feature/__init__.py", names)
        @test occursin(r"feature/_feature\..*\.(so|pyd)", names)

        # Import the :system wheel with ONLY JULIA_BINDIR set — no LD_LIBRARY_PATH.
        # This proves the ctypes RTLD_GLOBAL preload in __init__.py resolves libjulia
        # on its own (setting LD_LIBRARY_PATH from inside Python does not affect the
        # already-initialised loader). Windows handles DLLs differently — skip there.
        if !Sys.iswindows()
            extract = joinpath(outdir, "x")
            _py_run("import zipfile; zipfile.ZipFile($(repr(whl))).extractall($(repr(extract)))")
            out = _py_run_env("""
            import sys; sys.path.insert(0, $(repr(extract)))
            import feature
            assert feature.add(40, 2) == 42, "add"
            assert feature.greet("World") == "Hello, World!", "greet"
            print("SYS_OK")
            """, "JULIA_BINDIR" => Sys.BINDIR)
            @test occursin("SYS_OK", out)
        end
    end
end

# Item N: build_multi_wheel aggregates several @pymodule files into ONE extension
# (one jl_init) exposed as submodules, so they co-import in one process. Two
# separately-trimmed .so's cannot — each re-runs jl_init and aborts. Uses
# runtime=:system (no vendoring) for speed; the import sets ONLY JULIA_BINDIR — the
# ctypes RTLD_GLOBAL preload in __init__.py resolves libjulia without LD_LIBRARY_PATH.
@testset "integration: build_multi_wheel (item N)" begin
    if !_have_tools()
        @info "skipping build_multi_wheel integration test (need python3, a C compiler, and juliac)"
        @test_skip true
    else
        geo = joinpath(@__DIR__, "fixtures", "multi", "geo.jl")
        num = joinpath(@__DIR__, "fixtures", "multi", "num.jl")
        dup = joinpath(@__DIR__, "fixtures", "multi", "dup.jl")

        # Duplicate function name across sources is rejected (before any juliac run).
        @test_throws ErrorException build_multi_wheel([geo, dup], "bad"; runtime=:system,
                                                      outdir=mktempdir())

        outdir = mktempdir()
        whl = build_multi_wheel([geo, num], "mathpkg"; runtime=:system,
                                outdir=outdir, version="0.2.0")
        @test isfile(whl)
        # One extension; two submodule re-export files.
        names = _py_run("""
        import zipfile
        with zipfile.ZipFile($(repr(whl))) as z:
            print("\\n".join(z.namelist()))
        """)
        @test occursin("mathpkg/__init__.py", names)
        @test occursin("mathpkg/geo.py", names)
        @test occursin("mathpkg/num.py", names)
        @test occursin(r"mathpkg/_mathpkg\..*\.(so|pyd)", names)

        if Sys.iswindows()
            @info "Windows: multi-wheel built (co-import check skipped — see build_wheel notes)"
        else
            extract = joinpath(outdir, "x")
            _py_run("import zipfile; zipfile.ZipFile($(repr(whl))).extractall($(repr(extract)))")
            out = _py_run_env("""
            import sys; sys.path.insert(0, $(repr(extract)))
            import mathpkg
            assert mathpkg.geo.area(3.0, 4.0) == 12.0, "geo.area"
            assert mathpkg.num.gcd_(12, 18) == 6, "num.gcd_"
            # interleave both submodules in one process (shared runtime)
            assert mathpkg.geo.area(2.0, 5.0) == 10.0 and mathpkg.num.gcd_(9, 6) == 3
            print("MULTI_OK")
            """, "JULIA_BINDIR" => Sys.BINDIR)
            @test occursin("MULTI_OK", out)
        end
    end
end
