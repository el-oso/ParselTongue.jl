# Spike for item N (multi-module wheels): can two separately --trim-compiled
# ParselTongue extensions, both dynamically linked against the SAME system
# libjulia, be imported into ONE Python process and called?
#
# Run: julia --project=. spike/multi/run_spike.jl
using ParselTongue

outdir = mktempdir()
@info "Building aa + bb into $outdir"
so_aa = build_extension(joinpath(@__DIR__, "aa.jl"); outdir=outdir)
so_bb = build_extension(joinpath(@__DIR__, "bb.jl"); outdir=outdir)
@info "Built" so_aa so_bb

script = """
import sys
sys.path.insert(0, $(repr(outdir)))
import aa
print("aa imported; aa.add(40,2) =", aa.add(40, 2))
import bb
print("bb imported; bb.mul(6,7) =", bb.mul(6, 7))
# Interleave calls to make sure both runtimes stay live.
print("aa.add(1,1) =", aa.add(1, 1))
print("bb.mul(3,3) =", bb.mul(3, 3))
print("MULTI_OK")
"""

py = Sys.which("python3")
buf = IOBuffer()
try
    run(pipeline(`$py -c $script`, stdout=buf, stderr=buf))
    out = String(take!(buf))
    println(out)
    println(occursin("MULTI_OK", out) ? "SPIKE RESULT: PASS — two extensions coexist" :
                                        "SPIKE RESULT: FAIL — no MULTI_OK marker")
catch e
    out = String(take!(buf))
    println(out)
    println("SPIKE RESULT: FAIL — process aborted/errored: ", e)
end
