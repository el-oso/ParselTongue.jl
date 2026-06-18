# Classes & Objects

Beyond plain functions, ParselTongue can expose a Julia `struct` as a **real
Python class** — `isinstance` works, fields and dunder methods are available, and
(opt-in) Python code can even subclass it. This page walks through the class
features added after the original scalar/string/array examples:

- `@pyhandle` — an immutable struct as a Python object
- `@pymethod` — constructors (`__new__`), `__repr__`, operators, indexing, comparison
- `@pyproperty` — computed read-only attributes
- `@pymutable` — a mutable class whose fields you can write and whose state persists
- stateful iterators (`__iter__` / `__next__`) and context managers (`__enter__` / `__exit__`)

Everything on this page is one file, `shapes.jl`. The class declarations come
first; the [`@pymodule` that ties them together](#Tying-it-together) is at the end.
Every code block below is checked in CI — copy any of them as-is.

## An immutable handle: `Point`

```julia
# shapes.jl
using ParselTongue

struct Point
    x::Float64
    y::Float64
end

# Register Point as a Python class. subclass=true lets Python subclass it.
@pyhandle Point subclass=true

# Constructor: enables `Point(x, y)` from Python (instead of a factory function).
@pymethod __new__  point_new(x::Float64, y::Float64)::Point = Point(x, y)

# Nice repr and truthiness.
@pymethod __repr__ point_repr(p::Point)::String = string("Point(", p.x, ", ", p.y, ")")
@pymethod __bool__ point_bool(p::Point)::Bool   = p.x != 0.0 || p.y != 0.0

# Index it like a 2-element sequence (0-based).
@pymethod __getitem__ point_getitem(p::Point, i::Int64)::Float64 =
    i == 0 ? p.x : i == 1 ? p.y : error("Point index out of range: $i")

# Value equality (==); != is auto-derived. Ordering by norm (< and <=); Python
# derives > and >= by reflection.
@pymethod __eq__ point_eq(p::Point, q::Point)::Bool = p.x == q.x && p.y == q.y
@pymethod __lt__ point_lt(p::Point, q::Point)::Bool = (p.x^2 + p.y^2) < (q.x^2 + q.y^2)
@pymethod __le__ point_le(p::Point, q::Point)::Bool = (p.x^2 + p.y^2) <= (q.x^2 + q.y^2)

# Operators: Point ± Point, Point · Point (dot), -Point, |Point| (norm),
# and mixed-type Point/scalar and scalar*Point.
@pymethod __add__     point_add(p::Point, q::Point)::Point  = Point(p.x + q.x, p.y + q.y)
@pymethod __sub__     point_sub(p::Point, q::Point)::Point  = Point(p.x - q.x, p.y - q.y)
@pymethod __mul__     point_dot(p::Point, q::Point)::Float64 = p.x * q.x + p.y * q.y
@pymethod __neg__     point_neg(p::Point)::Point            = Point(-p.x, -p.y)
@pymethod __abs__     point_abs(p::Point)::Float64          = sqrt(p.x^2 + p.y^2)
@pymethod __truediv__ point_divk(p::Point, k::Float64)::Point = Point(p.x / k, p.y / k)
@pymethod __rmul__    point_scale(p::Point, k::Float64)::Point = Point(p.x * k, p.y * k)

# A computed, read-only property: `p.norm`.
@pyproperty Point norm::Float64 (p -> sqrt(p.x^2 + p.y^2))

# A bound named method that returns a new Point.
@pymethod translated(p::Point, dx::Float64, dy::Float64)::Point = Point(p.x + dx, p.y + dy)
```

Once built (see the bottom of the page), it behaves like any class:

```python
>>> import shapes
>>> p = shapes.Point(3.0, 4.0)
>>> p
Point(3.0, 4.0)
>>> isinstance(p, shapes.Point)
True
>>> p.norm                          # @pyproperty
5.0
>>> (p[0], p[1])                    # __getitem__
(3.0, 4.0)
>>> p + shapes.Point(1.0, 1.0)      # __add__
Point(4.0, 5.0)
>>> 2.0 * p                         # __rmul__ (reflected)
Point(6.0, 8.0)
>>> abs(p)                          # __abs__
5.0
>>> shapes.Point(1.0, 0.0) < p      # __lt__ (by norm)
True
>>> p.translated(1.0, -1.0)         # bound named method
Point(4.0, 3.0)
```

Because `subclass=true`, pure-Python code can extend it:

```python
>>> class Labelled(shapes.Point):
...     def describe(self):
...         return f"{self.norm:.1f} away"
...
>>> Labelled(3.0, 4.0).describe()
'5.0 away'
```

`Point` is an `isbits` struct, so each Python object stores a heap copy of the two
floats; the dunders compile to direct calls into the trimmed Julia.

## A mutable class: `Accumulator`

`@pymutable` registers a **mutable** struct (heap fields like `String` are allowed).
Its instances are backed by a Julia GC registry, so mutations persist on the live
object across calls:

```julia
mutable struct Accumulator
    total::Float64
    label::String
end
@pymutable Accumulator

@pymethod __new__ acc_new(label::String)::Accumulator = Accumulator(0.0, label)

# Bound methods that mutate / read the live object.
@pymethod add!(a::Accumulator, x::Float64)::Float64 = (a.total += x; a.total)
@pymethod describe(a::Accumulator)::String = string(a.label, ": ", a.total)
```

```python
>>> acc = shapes.Accumulator("sales")
>>> acc.add(10.0)
10.0
>>> acc.add(5.5)
15.5
>>> acc.describe()                  # state persisted across calls
'sales: 15.5'
>>> acc.total = 100.0               # scalar fields are writable
>>> acc.describe()
'sales: 100.0'
```

## A stateful iterator: `Counter`

A `@pymutable` type with `__iter__` (returns self) and `__next__` (advances state,
returns `Union{T, Nothing}`) is a Python iterator — `nothing` raises `StopIteration`:

```julia
mutable struct Counter
    cur::Int64
    stop::Int64
end
@pymutable Counter

@pymethod __new__  counter_new(stop::Int64)::Counter = Counter(0, stop)
@pymethod __iter__ counter_iter(c::Counter)::Counter = c
@pymethod __next__ counter_next(c::Counter)::Union{Int64,Nothing} =
    c.cur >= c.stop ? nothing : (c.cur += 1; c.cur - 1)
```

```python
>>> list(shapes.Counter(4))
[0, 1, 2, 3]
>>> [i * i for i in shapes.Counter(3)]
[0, 1, 4]
```

## A context manager: `Session`

`__enter__` / `__exit__` make a handle usable in a `with` statement. `__enter__`
returns the object bound by `as`; `__exit__` returns a `Bool` (`false` = don't
suppress exceptions):

```julia
mutable struct Session
    name::String
end
@pymutable Session

@pymethod __new__   session_new(name::String)::Session = Session(name)
@pymethod __enter__ session_enter(s::Session)::Session = s
@pymethod __exit__  session_exit(s::Session)::Bool = false
@pymethod __repr__  session_repr(s::Session)::String = string("Session(", s.name, ")")
```

```python
>>> with shapes.Session("job") as s:
...     print(s)
Session(job)
```

## Tying it together

The class declarations above live at the **top level** of `shapes.jl`. Registered
classes attach to the module automatically, so the `@pymodule` block at the end of
the file only needs your free functions:

```julia
@pymodule shapes begin
    # Functions can take and return the handle types declared above.
    @pyfunc midpoint(p::Point, q::Point)::Point = Point((p.x + q.x) / 2, (p.y + q.y) / 2)
end
```

```python
>>> shapes.midpoint(shapes.Point(0.0, 0.0), shapes.Point(2.0, 4.0))
Point(1.0, 2.0)
```

Build and install it like any other module:

```julia
using ParselTongue
build_wheel("shapes.jl")
```

See the [boundary-types guide](/guide/boundary-types) for the full list of
supported dunders and the rules each one follows.
