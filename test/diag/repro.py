#!/usr/bin/env python3
# Segfault diagnostic for the Linux-CI integration crash. Imports the prebuilt
# `feature` extension (path via FEATURE_DIR env) and exercises the same calls as
# test/test_integration.jl, printing a progress marker to stderr before each
# group so the last marker pinpoints the crashing step. Run under gdb in CI to
# also capture the native backtrace (Julia's embedded SIGSEGV handler otherwise
# preempts Python's faulthandler).
import os
import sys
import array
import cmath
import faulthandler

faulthandler.enable()
sys.path.insert(0, os.environ["FEATURE_DIR"])


def mark(msg):
    print(f"[repro] {msg}", file=sys.stderr, flush=True)


mark("importing feature")
import feature

mark("scalars")
assert feature.add(40, 2) == 42
assert feature.is_even(10) is True and feature.is_even(7) is False
assert feature.greet("World") == "Hello, World!"
assert feature.conj1(3 + 4j) == 3 - 4j

mark("arrays (buffer)")
assert feature.sum_f64(array.array("d", [1.0, 2.0, 3.0, 4.0])) == 10.0
assert feature.minmax(array.array("d", [3.0, 1.0, 5.0])) == (1.0, 5.0)
x = array.array("d", [1.0, 2.0, 3.0])
assert feature.scale(x, 10.0) is None and list(x) == [10.0, 20.0, 30.0]

mark("numpy block")
try:
    import numpy as np
    A = np.array([[1.0, 2.0, 3.0], [4.0, 5.0, 6.0]])
    assert np.allclose(feature.rowsums(A), [6.0, 15.0])
    assert list(feature.dims(A)) == [3, 2]
    mark("numpy ok")
except ImportError:
    mark("numpy absent")

mark("exceptions")
try:
    feature.boom()
    assert False
except RuntimeError:
    pass

mark("strings (list[str])")
assert feature.words("hello world") == ["hello", "world"]
assert feature.join_words(["a", "b", "c"]) == "a b c"

mark("callables (scalar)")
assert feature.apply(lambda v: v * 2.0, 3.0) == 6.0
assert feature.combine(lambda a, b: a + b, 3, 4) == 7

mark("callables (String)")
assert feature.apply_str(str.upper, "hello") == "HELLO"
assert feature.apply_str(lambda s: s[::-1], "abc") == "cba"

mark("callables (Vector)")
assert list(feature.apply_vec(lambda v: [y * 2.0 for y in v], array.array("d", [1.0, 2.0, 3.0]))) == [2.0, 4.0, 6.0]
assert list(feature.apply_vec(sorted, array.array("d", [3.0, 1.0, 2.0]))) == [1.0, 2.0, 3.0]

mark("refleak stress loop")
import gc as _gc


def _no_refleak(fn, *args, n=2000):
    fn(*args)
    base = [sys.getrefcount(a) for a in args]
    for _ in range(n):
        _r = fn(*args)
        del _r
    _gc.collect()
    after = [sys.getrefcount(a) for a in args]
    assert after == base, f"arg refcount leak in {fn}: {base} -> {after}"


_no_refleak(feature.greet, "World")
_no_refleak(feature.sum_f64, array.array("d", [1.0, 2.0, 3.0]))
_no_refleak(feature.words, "alpha beta gamma")
_no_refleak(feature.apply, (lambda v: v * 2.0), 4.0)

mark("ALL OK")
print("REPRO_OK")
