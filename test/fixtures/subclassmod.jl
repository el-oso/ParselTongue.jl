using ParselTongue

# Subclassable @pymutable with a per-instance __dict__ (dict=true). A Python subclass
# can add methods, override dunders, and set arbitrary instance attributes; the type is
# a GC type so reference cycles through the dict are collected. dict=true needs the full
# (non-abi3) API.
mutable struct Bag
    n::Int64
    name::String
end
@pymutable Bag subclass=true dict=true
@pymethod __new__ bag_new(name::String)::Bag = Bag(0, name)
@pymethod __repr__ bag_repr(b::Bag)::String = "Bag($(b.name), n=$(b.n))"
@pymethod bump!(b::Bag)::Int64 = (b.n += 1; b.n)

@pymodule subclassmod begin
    @pyfunc bag_count(b::Bag)::Int64 = b.n
end
