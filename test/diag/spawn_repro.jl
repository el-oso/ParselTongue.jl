# Reproduces the integration test's exact subprocess spawn to isolate the
# Linux-CI segfault. test/test_integration.jl's `_py_run` does
# `run(pipeline(`python3 -c $script`))`, which inherits the Julia process's full
# environment. This script runs test/diag/repro.py two ways against a prebuilt
# `feature` extension (FEATURE_DIR env):
#   A) inherited env  — exactly like _py_run (the suspected-crashing path)
#   B) scrubbed env   — LD_LIBRARY_PATH / LD_PRELOAD removed (the candidate fix)
# Compare the two to confirm whether an inherited library path is the cause.
using ParselTongue  # load libjulia into THIS process, mirroring the test process

const PY = Sys.which("python3")
const REPRO = joinpath(@__DIR__, "repro.py")

println("\n========== A) inherited-env spawn (mimics _py_run) ==========")
flush(stdout)
a = run(ignorestatus(`$PY $REPRO`))
println("A exit code: ", a.exitcode)

println("\n========== B) scrubbed-env spawn (LD_LIBRARY_PATH/LD_PRELOAD removed) ==========")
flush(stdout)
b = run(ignorestatus(addenv(`$PY $REPRO`, "LD_LIBRARY_PATH" => nothing, "LD_PRELOAD" => nothing)))
println("B exit code: ", b.exitcode)
