using ParselTongue
using ErrorTypes

# SPIKE: internal error handling with Rust-style Result + `@?` propagation instead of
# exceptions. Each step returns Result{Float64,Symbol}; `@?` early-returns the Err up the
# chain — a typed, exception-free propagation the compiler infers concretely. The @pyfunc
# boundary consumes the final Result with `@unwrap_or` (no throw, so this particular error
# path needs no try/catch). The generated @ccallable still wraps the body in the trim-safe
# boundary catch for *other* exceptions — Result complements it, it does not replace it.

# returns Err(:nonpositive) for x <= 0, else Ok(x)
function _require_pos(x::Float64)::Result{Float64, Symbol}
    return x > 0.0 ? Ok(x) : Err(:nonpositive)
end

# returns Err(:too_big) for v > 1e6, else Ok(v)
function _require_small(v::Float64)::Result{Float64, Symbol}
    return v > 1.0e6 ? Err(:too_big) : Ok(v)
end

# multi-step pipeline; `@?` propagates the first Err without exceptions
function _pipeline(x::Float64)::Result{Float64, Symbol}
    v = @? _require_pos(x)
    w = @? _require_small(v)
    return Ok(log(sqrt(w)))
end

@pymodule errtypes_demo begin
    # Boundary consumes the Result without throwing: NaN sentinel on any Err.
    @pyfunc logsqrt(x::Float64)::Float64 = @unwrap_or(_pipeline(x), NaN)
end
