# app/pt.jl — thin wrapper for juliac --output-exe compilation.
#
# Run directly (no compile step):
#   julia --project=. app/pt.jl build FILE.jl [OPTIONS]
#
# Compile to a standalone binary (see app/build_app.jl):
#   julia --project=. app/build_app.jl        # → ./pt
#   ./pt build FILE.jl [OPTIONS]
#
# juliac --output-exe requires julia_main()::Cint in Main. Bringing it in via
# `using` (not `import`) puts it in the Main namespace, satisfying juliac.
# The actual implementation lives in src/cli.jl (included by the ParselTongue module).

using ParselTongue: julia_main
