module ParselTongue

using TypeContracts
using MLStyle

# NOTE: we do NOT depend on BaseTypeContracts — ParselTongue defines its own
# PyBoundary contract and carrier types here; the Base contracts it provides are
# not needed. (TypeContracts itself has no __init__, so trim-safety is not a concern.)

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

# CLI (pt): also exposes julia_main() so `julia -m ParselTongue` works (Pkg Apps).
include("cli.jl")

export @pyfunc, @pymodule, @pyhandle, @pymutable, @pymethod, @pyerror, @boundary, @pyproperty, build_extension, build_wheel, build_multi_wheel, build_runtime_wheel
export bundle_size_report, startup_benchmark
export PyBoundary, Mut, PtHandle, PtVarArgs, PyCallable, c_abi_type, from_c, to_c
export julia_main

end # module ParselTongue
