using ParselTongue

@pymodule bb begin
    @pyfunc mul(a::Int64, b::Int64)::Int64 = a * b
end
