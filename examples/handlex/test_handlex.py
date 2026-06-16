"""Smoke test for the handlex example. Run after building the extension:

    julia --project=. -e 'using ParselTongue; build_extension("examples/handlex/handlex.jl"; outdir="build")'
    PYTHONPATH=build python3 examples/handlex/test_handlex.py
"""
import handlex

# Real Python class — isinstance works.
p = handlex.make_point(3.0, 4.0)
assert isinstance(p, handlex.Point2D), f"expected Point2D, got {type(p)}"
assert type(p).__name__ == "Point2D"

# repr shows the type name.
assert repr(p) == "<Point2D>", repr(p)

# Accessors.
assert handlex.px(p) == 3.0
assert handlex.py(p) == 4.0
assert abs(handlex.norm(p) - 5.0) < 1e-12

# Functional mutation returns a new handle of the same type.
p2 = handlex.translate(p, 1.0, 2.0)
assert isinstance(p2, handlex.Point2D)
assert handlex.px(p2) == 4.0
assert handlex.py(p2) == 6.0

p3 = handlex.scale(p, 2.0)
assert isinstance(p3, handlex.Point2D)
assert handlex.px(p3) == 6.0
assert handlex.py(p3) == 8.0

print("OK")
