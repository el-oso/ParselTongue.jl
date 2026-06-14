# app/build_app.jl — Compile the `pt` CLI binary using juliac.
#
# Run from the parseltongue project root:
#   julia --project=. app/build_app.jl          # → ./pt
#   julia --project=. app/build_app.jl /out/pt  # → custom path
#
# Requirements: Julia ≥ 1.12 with juliac (ships by default), a C compiler.
#
# Why --trim=unsafe:
#   build_extension / build_wheel call Core.eval and Base.include at runtime to
#   load the user's source file.  --trim=safe rejects dynamic dispatch reachable
#   from any entrypoint, which would include those calls.  --trim=unsafe trims
#   unreachable code but allows runtime dynamic dispatch to succeed.
#
# The compiled binary embeds ParselTongue in its sysimage.  When a user runs
#   `pt build mymod.jl`
# the binary calls build_extension in-process, which spawns a juliac subprocess
# that inherits the active project (the parseltongue project directory baked in
# at compile time via Base.active_project()), so `using ParselTongue` inside the
# user's module finds the package.

julia_bin = Base.julia_cmd().exec[1]
juliac_jl = joinpath(Sys.BINDIR, Base.DATAROOTDIR, "julia", "juliac", "juliac.jl")
isfile(juliac_jl) || error(
    "juliac.jl not found at $juliac_jl — requires Julia ≥ 1.12 with juliac.")

app_src = abspath(joinpath(@__DIR__, "pt.jl"))
isfile(app_src) || error("app source not found: $app_src")

outfile = abspath(isempty(ARGS) ? joinpath(@__DIR__, "..", "pt") : ARGS[1])
project = Base.active_project()

@info "ParselTongue: building pt binary" src=app_src out=outfile project

cmd = `$julia_bin --startup-file=no --history-file=no --project=$project
       $juliac_jl --output-exe $outfile --experimental --trim=unsafe $app_src`

run(addenv(cmd, "OPENBLAS_NUM_THREADS" => "1", "JULIA_NUM_THREADS" => "1"))

@info "Done: $outfile  (run: ./pt help)"
