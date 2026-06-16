using ParselTongue

@pymodule geo begin
    @pyfunc area(w::Float64, h::Float64)::Float64 = w * h
end
