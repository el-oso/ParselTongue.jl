using ParselTongue

@pymodule num begin
    @pyfunc gcd_(a::Int64, b::Int64)::Int64 = gcd(a, b)
end
