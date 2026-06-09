using ParselTongue

@pymodule mathx begin

    @pyfunc add(a::Int64, b::Int64)::Int64 = a + b

    @pyfunc function fma2(x::Float64, y::Float64, z::Float64)::Float64
        return x * y + z
    end

    @pyfunc is_even(n::Int64)::Bool = iseven(n)

    @pyfunc "scale" scale_f32(v::Float32, k::Float32)::Float32 = v * k

end
