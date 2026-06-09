using Test

@testset "ParselTongue.jl" begin
    # Fast, build-free unit tests: boundary type system, macros, C/Julia codegen.
    include("test_m2_boundary_macros.jl")
    # End-to-end build + import (juliac --trim, C shim, link). Slower; skips
    # automatically if python3 / a C compiler / juliac are unavailable.
    include("test_integration.jl")
end
