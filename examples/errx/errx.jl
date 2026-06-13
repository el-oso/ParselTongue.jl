using ParselTongue

@pymodule errx begin
    @pyfunc safe_div(a::Float64, b::Float64)::Float64 = b == 0.0 ? error("division by zero") : a / b
    @pyfunc sqrt_pos(x::Float64)::Float64 = x < 0.0 ? error("sqrt of negative number: $x") : sqrt(x)
end
