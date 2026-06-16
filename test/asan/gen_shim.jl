# Generate the C shim for test/fixtures/asan_carriers.jl and print it to stdout.
# Used by the ASan CI job (test/asan/driver.c #includes the generated file).
# Keeps the harness in lockstep with the live cshim.jl generator — no golden file.
#
#   julia --project=. test/asan/gen_shim.jl > shim_generated.c
using ParselTongue
using ParselTongue: emit_cshim, _EXPORTS, _ERRORS, _HANDLE_TYPES, _METHODS, clear_exports!

clear_exports!()
Base.include(Module(:AsanSandbox), joinpath(@__DIR__, "..", "fixtures", "asan_carriers.jl"))
print(emit_cshim("asan_carriers", _EXPORTS, _ERRORS, _HANDLE_TYPES, _METHODS))
