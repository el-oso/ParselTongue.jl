using ParselTongue

# A subclassable @pymutable type: Python can `class Sub(Bag): ...`, adding methods
# and overriding dunders, while inheriting the constructor, bound methods, and fields.
mutable struct Bag
    n::Int64
    name::String
end
@pymutable Bag subclass=true
@pymethod __new__ bag_new(name::String)::Bag = Bag(0, name)
@pymethod __repr__ bag_repr(b::Bag)::String = "Bag($(b.name), n=$(b.n))"
@pymethod bump!(b::Bag)::Int64 = (b.n += 1; b.n)

@pymodule subclassmod begin
    @pyfunc bag_count(b::Bag)::Int64 = b.n
end
