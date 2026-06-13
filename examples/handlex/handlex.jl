using ParselTongue

# Opaque-handle example: a 2-D point stored on the C heap.
#
# @pyhandle T requires T to be an isbitstype (immutable struct with all-isbits
# fields). Python sees a PyCapsule; free() is called when the capsule is GC'd.
# Mutation is functional: each "update" returns a new handle (old one is freed
# when Python drops its reference).

struct Point2D
    x::Float64
    y::Float64
end
@pyhandle Point2D

@pymodule handlex begin
    # Constructor — returns a new PyCapsule wrapping a malloc'd Point2D.
    @pyfunc make_point(x::Float64, y::Float64)::Point2D = Point2D(x, y)

    # Read accessors.
    @pyfunc px(p::Point2D)::Float64 = p.x
    @pyfunc py(p::Point2D)::Float64 = p.y
    @pyfunc norm(p::Point2D)::Float64 = sqrt(p.x^2 + p.y^2)

    # Functional "update": returns a new handle; Python GC frees the old one.
    @pyfunc translate(p::Point2D, dx::Float64, dy::Float64)::Point2D =
        Point2D(p.x + dx, p.y + dy)
    @pyfunc scale(p::Point2D, k::Float64)::Point2D = Point2D(p.x * k, p.y * k)
end
