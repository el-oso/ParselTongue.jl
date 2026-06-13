using ParselTongue

@pymodule kwx begin
    # Keyword argument with a default: Python can call power(2.0) or power(2.0, exponent=3.0).
    @pyfunc power(base::Float64; exponent::Float64=2.0)::Float64 = base ^ exponent

    # Multiple keyword defaults: clamp_val(x) uses [0, 1]; clamp_val(x, lo=0.2, hi=0.8) is custom.
    @pyfunc clamp_val(x::Float64; lo::Float64=0.0, hi::Float64=1.0)::Float64 = clamp(x, lo, hi)

    # Positional arg with default: round_to(3.14159) uses 2 decimal places.
    @pyfunc round_to(x::Float64, digits::Int64=2)::Float64 = round(x; digits)
end
