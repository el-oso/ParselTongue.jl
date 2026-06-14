module ParselTongue

using TypeContracts

# NOTE: we deliberately do NOT depend on BaseTypeContracts. Its `__init__`
# registers Base contracts at runtime, and module `__init__`s are `juliac --trim`
# entrypoints — pulling it in makes the trimmed extension fail trim verification.
# ParselTongue's boundary needs only `c_abi_type`/`from_c`/`to_c`, defined here.

# Boundary type system: PyBoundary contract + conversions (Julia <-> C-ABI).
include("boundary.jl")

# @pyfunc / @pymodule: record which functions are exported and their signatures.
include("macros.jl")

# Codegen: Julia-side @ccallable wrappers from recorded metadata.
include("ccallable_gen.jl")

# C-shim codegen, build driver, wheel packaging.
include("cshim.jl")
include("build.jl")
include("wheel.jl")

export @pyfunc, @pymodule, @pyhandle, @pyerror, @boundary, build_extension, build_wheel, build_runtime_wheel
export bundle_size_report, startup_benchmark
export PyBoundary, Mut, PtHandle, PtVarArgs, c_abi_type, from_c, to_c

end # module ParselTongue
