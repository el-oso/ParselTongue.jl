using ParselTongue

# A @pymutable type that is both subclassable and carries an instance __dict__.
# dict=true needs CPython ≥ 3.12 (managed dict) and is incompatible with abi3 — so this
# fixture is built without abi3 and exercises the dict=true + abi3 guard separately.
mutable struct Bag
    n::Int64
    name::String
end
@pymutable Bag subclass=true dict=true
@pymethod __new__ bag_new(name::String)::Bag = Bag(0, name)
@pymethod bump!(b::Bag)::Int64 = (b.n += 1; b.n)

@pymodule subclassmod begin
    @pyfunc bag_count(b::Bag)::Int64 = b.n
end
