import os, sys, array, cmath
import faulthandler; faulthandler.enable()   # print the Python line on any segfault
sys.path.insert(0, os.environ["FEATURE_DIR"])
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
# Non-scalar callable signatures (item L): String and Vector{Float64}
assert feature.apply_str(str.upper, "hello") == "HELLO",  "apply_str: upper"
assert feature.apply_str(lambda s: s[::-1], "abc") == "cba", "apply_str: reverse"
assert list(feature.apply_vec(lambda v: [x * 2.0 for x in v], array.array("d", [1.0, 2.0, 3.0]))) == [2.0, 4.0, 6.0], "apply_vec: double"
assert list(feature.apply_vec(sorted, array.array("d", [3.0, 1.0, 2.0]))) == [1.0, 2.0, 3.0], "apply_vec: sorted"
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
