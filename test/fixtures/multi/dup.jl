using ParselTongue

# Intentionally exports `area` too — used to test the cross-source duplicate
# function-name guard in build_multi_wheel.
@pymodule dup begin
    @pyfunc area(r::Float64)::Float64 = 3.14159 * r * r
end
