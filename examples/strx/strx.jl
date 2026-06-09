using ParselTongue

@pymodule strx begin
    @pyfunc greet(name::String)::String = "Hello, " * name * "!"
    @pyfunc shout(s::String)::String = uppercase(s)
    @pyfunc strlen(s::String)::Int64 = Int64(length(s))
end
