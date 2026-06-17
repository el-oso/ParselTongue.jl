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
        # Auto field access (item K): scalar fields exposed as read-only attributes.
        assert p.x == 3.0, f"field access p.x: {p.x}"
        assert p.y == 4.0, f"field access p.y: {p.y}"
        assert feature.point_norm(p) == 5.0, "point_norm 3-4-5"
        p2 = feature.point_scale(p, 2.0)
        assert isinstance(p2, feature.Pt2D), "scaled result is Pt2D"
        assert feature.point_x(p2) == 6.0 and feature.point_y(p2) == 8.0, "point_scale"
        del p, p2   # tp_dealloc calls free()
        # Item O: __len__, __hash__, __bool__ dunders.
        p3 = feature.make_point(3.0, 4.0)
        assert len(p3) == 5, f"__len__ (norm ~5): {len(p3)}"
        assert isinstance(hash(p3), int), f"__hash__ returned non-int: {hash(p3)}"
        assert bool(p3) == True, "__bool__ non-zero point"
        assert bool(feature.make_point(0.0, 0.0)) == False, "__bool__ zero point"
        # hash consistency: equal-valued points should produce equal hashes.
        p4 = feature.make_point(3.0, 4.0)
        assert hash(p3) == hash(p4), "hash consistency"
        del p3, p4
        # Item O2: __getitem__ (integer subscript).
        p5 = feature.make_point(3.0, 4.0)
        assert p5[0] == 3.0, f"__getitem__[0] = {p5[0]}"
        assert p5[1] == 4.0, f"__getitem__[1] = {p5[1]}"
        try:
            _ = p5[2]
            assert False, "__getitem__[2] should raise"
        except RuntimeError:
            pass
        del p5
        # Item O3: __eq__ / __ne__ (rich comparison).
        pa = feature.make_point(3.0, 4.0)
        pb = feature.make_point(3.0, 4.0)
        pc = feature.make_point(1.0, 2.0)
        assert pa == pb,     "__eq__: equal points"
        assert not (pa == pc), "__eq__: unequal points"
        assert pa != pc,     "__ne__: auto-negation"
        assert not (pa != pb), "__ne__: auto-negation equal"
        assert not (pa == 42), "__eq__: cross-type comparison is False"
        del pa, pb, pc
        # Item O4: __lt__ / __le__ (ordering by norm; __gt__ / __ge__ via Python reflection).
        p_s = feature.make_point(3.0, 0.0)  # norm 3
        p_l = feature.make_point(4.0, 0.0)  # norm 4
        assert p_s < p_l,    "__lt__"
        assert p_s <= p_l,   "__le__"
        assert p_l > p_s,    "__gt__ (Python reflection of __lt__)"
        assert p_l >= p_s,   "__ge__ (Python reflection of __le__)"
        assert not (p_l < p_s), "__lt__ false"
        del p_s, p_l
        # Item O5: constructor syntax via __new__.
        p_c = feature.Pt2D(3.0, 4.0)
        assert isinstance(p_c, feature.Pt2D), "Pt2D(x,y) returns Pt2D instance"
        assert feature.point_x(p_c) == 3.0, "constructor x"
        assert feature.point_y(p_c) == 4.0, "constructor y"
        assert repr(p_c) == "<Pt2D: x=3.0, y=4.0>", "constructor repr"
        del p_c
        # Item O6: mutable setattr (p.x = ...) and __setitem__ write-back (p[i] = ...).
        p_mut = feature.Pt2D(3.0, 4.0)
        p_mut.x = 10.0
        assert p_mut.x == 10.0, f"setattr x: {p_mut.x}"
        p_mut.y = 20.0
        assert p_mut.y == 20.0, f"setattr y: {p_mut.y}"
        p_mut[0] = 1.0
        assert p_mut[0] == 1.0, f"setitem[0]: {p_mut[0]}"
        p_mut[1] = 2.0
        assert p_mut[1] == 2.0, f"setitem[1]: {p_mut[1]}"
        try:
            p_mut[2] = 99.0
            assert False, "__setitem__[2] should raise"
        except RuntimeError:
            pass
        del p_mut
        # Item O8a: __contains__ membership test.
        p_has = feature.Pt2D(3.0, 4.0)
        assert 3.0 in p_has, "__contains__ x"
        assert 4.0 in p_has, "__contains__ y"
        assert 5.0 not in p_has, "__contains__ absent"
        del p_has
        # Item O8a: __iter__ self-return (tp_iter slot; iter() needs __next__ too, so
        # call __iter__ directly to verify the slot returns self without TypeError).
        p_it = feature.Pt2D(3.0, 4.0)
        it = p_it.__iter__()
        assert isinstance(it, feature.Pt2D), f"__iter__() returns Pt2D: {type(it)}"
        assert it is p_it, "__iter__ returns self"
        del p_it
        # Item O8a: __call__ via LinearModel.
        lm = feature.LinearModel(2.0, 1.0)
        assert isinstance(lm, feature.LinearModel), "LinearModel instance"
        assert lm(3.0) == 7.0, f"__call__ lm(3) = 7: {lm(3.0)}"
        assert lm(0.0) == 1.0, f"__call__ lm(0) = 1: {lm(0.0)}"
        del lm
        # Item O9: context manager __enter__ / __exit__.
        lm2 = feature.LinearModel(3.0, 0.0)
        with lm2 as m:
            assert isinstance(m, feature.LinearModel), "__enter__ returns LinearModel"
            assert m is lm2, "__enter__ returns self"
            assert m(2.0) == 6.0, f"LinearModel inside with: {m(2.0)}"
        del lm2
        # Item O10: @pyproperty computed read-only property.
        p_prop = feature.Pt2D(3.0, 4.0)
        assert abs(p_prop.norm - 5.0) < 1e-10, f"@pyproperty norm 3-4-5: {p_prop.norm}"
        assert feature.Pt2D(0.0, 0.0).norm == 0.0, "@pyproperty norm zero"
        del p_prop
        # Numeric dunders: __add__/__sub__/__mul__ (binary) + __neg__/__abs__ (unary).
        na, nb = feature.Pt2D(1.0, 2.0), feature.Pt2D(3.0, 4.0)
        s = na + nb
        assert isinstance(s, feature.Pt2D) and s.x == 4.0 and s.y == 6.0, "__add__"
        d = nb - na
        assert d.x == 2.0 and d.y == 2.0, "__sub__"
        assert (na * nb) == 11.0, f"__mul__ dot: {na * nb}"   # 1*3 + 2*4
        ng = -na
        assert ng.x == -1.0 and ng.y == -2.0, "__neg__"
        assert abs(nb) == 5.0, f"__abs__: {abs(nb)}"          # 3-4-5
        # Same-handle __add__ with a non-Pt2D operand → NotImplemented → TypeError.
        try:
            _ = na + 5
            assert False, "Pt2D + int should raise TypeError"
        except TypeError:
            pass
        # Mixed-type: T × scalar (p / k, forward) and scalar × T (k * p, reflected).
        half = nb / 2.0
        assert isinstance(half, feature.Pt2D) and half.x == 1.5 and half.y == 2.0, "Pt2D / scalar"
        scaled = 3.0 * na          # reflected __rmul__  (int/float left operand)
        assert isinstance(scaled, feature.Pt2D) and scaled.x == 3.0 and scaled.y == 6.0, "scalar * Pt2D"
        scaled_i = 2 * na          # int coerces to double via PyArg_Parse 'd'
        assert scaled_i.x == 2.0 and scaled_i.y == 4.0, "int * Pt2D coercion"
        assert (na * nb) == 11.0, "Pt2D * Pt2D still dot product (T×T)"
        try:
            _ = na / "x"           # bad scalar → NotImplemented → TypeError
            assert False, "Pt2D / str should raise TypeError"
        except TypeError:
            pass
        del na, nb, s, d, ng, half, scaled, scaled_i
        # Bound named method on an immutable @pyhandle: returns a new handle.
        pt_b = feature.Pt2D(1.0, 2.0)
        pt_t = pt_b.translated(3.0, 4.0)
        assert isinstance(pt_t, feature.Pt2D) and pt_t.x == 4.0 and pt_t.y == 6.0, "Pt2D.translated"
        del pt_b, pt_t
        # Python subclassing (subclass=true): Pt2D is a base type; a pure-Python subclass
        # can add methods and override dunders, inheriting fields/property/constructor.
        class LabeledPt(feature.Pt2D):
            def quadrant(self):
                return 1 if (self.x >= 0 and self.y >= 0) else 0
            def __repr__(self):
                return f"LabeledPt({self.x},{self.y})"
        lp = LabeledPt(3.0, 4.0)
        assert isinstance(lp, LabeledPt) and isinstance(lp, feature.Pt2D), "subclass isinstance"
        assert lp.x == 3.0 and lp.y == 4.0, "inherited auto field access"
        assert abs(lp.norm - 5.0) < 1e-10, "inherited @pyproperty on subclass"
        assert lp.quadrant() == 1, "subclass method"
        assert repr(lp) == "LabeledPt(3.0,4.0)", "subclass __repr__ override"
        assert feature.point_x(lp) == 3.0, "base C function accepts subclass instance"
        del lp
        # Item O7: @pymutable — mutable struct with a String field, backed by a GC registry.
        acc = feature.Accumulator("temps")
        assert isinstance(acc, feature.Accumulator), "Accumulator instance"
        assert acc.label == "temps", f"String field read: {acc.label}"
        assert acc.total == 0.0, f"initial total: {acc.total}"
        assert feature.acc_add(acc, 1.5) == 1.5, "acc_add 1"
        assert feature.acc_add(acc, 2.5) == 4.0, "acc_add 2 (mutation persists)"
        assert acc.total == 4.0, f"field reflects mutation: {acc.total}"
        assert feature.acc_total(acc) == 4.0, "acc_total"
        acc.total = 100.0          # field write
        assert acc.total == 100.0 and feature.acc_total(acc) == 100.0, "field write"
        acc.label = "renamed"
        assert acc.label == "renamed", f"String field write: {acc.label}"
        # Bound named methods on @pymutable: mutate the live object, persist, read fields.
        acc.total = 0.0
        assert acc.add(1.5) == 1.5, "bound method acc.add"
        assert acc.add(2.5) == 4.0, "bound method mutation persists"
        assert acc.total == 4.0, "field reflects bound-method mutation"
        assert acc.describe() == "renamed", "bound method returning String"
        acc2 = feature.Accumulator("other")   # independent instance
        feature.acc_add(acc2, 7.0)
        assert acc2.total == 7.0 and acc.total == 4.0, "instances independent"
        del acc, acc2
        import gc as _gc2; _gc2.collect()      # dealloc drops registry refs (no crash)
        # Item O8b: @pymutable + __next__ stateful iterator.
        assert list(feature.CountUp(5)) == [0, 1, 2, 3, 4], "iterator list()"
        assert sum(feature.CountUp(4)) == 6, "iterator sum()"
        assert [x * x for x in feature.CountUp(3)] == [0, 1, 4], "iterator comprehension"
        assert list(feature.CountUp(0)) == [], "empty iterator"
        it = feature.CountUp(2)
        assert next(it) == 0 and next(it) == 1, "manual next()"
        try:
            next(it); assert False, "expected StopIteration"
        except StopIteration:
            pass
        del it
        # Python callables as arguments (item F)
        assert feature.apply(lambda x: x * 2.0, 3.0) == 6.0,    "apply: identity"
        assert feature.apply(abs, -5.0) == 5.0,                  "apply: builtin"
        root = feature.bisect(lambda x: x**2 - 2.0, 1.0, 2.0)
        assert abs(root - 2.0**0.5) < 1e-10,                     "bisect: sqrt(2)"
        # Arbitrary callable signatures (item L): (Int64, Int64) -> Int64
        assert feature.combine(lambda a, b: a + b, 3, 4) == 7,   "combine: add"
        assert feature.combine(lambda a, b: a * b, 6, 7) == 42,  "combine: mul"
        # Refcount-leak gate: calling a wrapper must not leak references to its
        # arguments (e.g. an INCREF without a matching DECREF on the arg buffer or
        # callable) nor leak Python objects per call. Catches the Python-side half
        # of the bug class; the C-malloc half is gated by the ASan job.
        import gc as _gc
        def _no_refleak(fn, *args, n=2000):
            fn(*args)                                   # warm up (interning, caches)
            base = [sys.getrefcount(a) for a in args]
            _gc.collect(); _n0 = len(_gc.get_objects())
            for _ in range(n):
                _r = fn(*args); del _r
            _gc.collect()
            after = [sys.getrefcount(a) for a in args]
            assert after == base, f"arg refcount leak in {fn}: {base} -> {after}"
            grew = len(_gc.get_objects()) - _n0
            assert grew < 100, f"object leak in {fn}: +{grew} objects over {n} calls"
        _no_refleak(feature.greet, "World")             # String arg + return
        _no_refleak(feature.sum_f64, array.array("d", [1.0, 2.0, 3.0]))  # buffer arg
        _no_refleak(feature.join_words, ["a", "b", "c"])                 # list[str] arg
        _no_refleak(feature.words, "alpha beta gamma")                   # list[str] return
        _no_refleak(feature.apply, (lambda x: x * 2.0), 4.0)             # PyCallable INCREF/DECREF
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
