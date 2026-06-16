using ParselTongue

@pymodule aa begin
    @pyfunc add(a::Int64, b::Int64)::Int64 = a + b
end
