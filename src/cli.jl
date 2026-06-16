# ── pt CLI — ParselTongue command-line interface ──────────────────────
#
# Included by src/ParselTongue.jl so that `julia -m ParselTongue [args]`
# (Pkg Apps, Julia 1.12+) finds julia_main() inside the module.
#
# app/pt.jl is a thin wrapper that brings julia_main into Main for juliac.

const _PT_CLI_VERSION = string(pkgversion(@__MODULE__))

const _USAGE = """
pt — ParselTongue.jl CLI  (v$_PT_CLI_VERSION)

Commands:
  pt build  FILE.jl  [OPTIONS]   Compile a CPython extension (.so)
  pt wheel  FILE.jl  [OPTIONS]   Build a pip-installable wheel
  pt bench  EXT.so   [OPTIONS]   Measure import + first-call latency
  pt version                     Print version string
  pt help                        Show this help

Options (build):
  --outdir=DIR            Output directory          (default: dir of FILE)
  --mod-name=NAME         Python module name        (default: @pymodule / filename)
  --trim=safe|unsafe      juliac trim level         (default: safe)
  --abi3                  Stable-ABI .abi3.so for CPython ≥ 3.11
  --verbose               Print juliac and cc commands

Options (wheel):
  --outdir=DIR            Output directory          (default: dist)
  --version=X.Y.Z         Wheel version string      (default: 0.1.0)
  --mod-name=NAME         Python module name
  --trim=safe|unsafe      juliac trim level         (default: safe)
  --manylinux=VER|false   Platform tag: "2.17", "2.28", false, or "true"/auto
  --runtime=bundled|shared|system
                          bundled: self-contained ~100 MB (default)
                          shared:  ~1 MB + parseltongue-runtime dependency
                          system:  ~1 MB, requires Julia on target machine
  --slim                  Exclude large optional runtime libs (bundled only)
  --verbose               Print commands

Options (bench):
  --call=EXPR             Python expression to time after import (e.g. "mod.f(1)")
  --n=N                   Number of fresh-process trials         (default: 5)
"""

# ── Argument parser ───────────────────────────────────────────────────────────

"""
    _parse_flags(args) -> (positionals::Vector{String}, flags::Dict{String,String})

Split `args` into positional strings and `--key=value` / `--flag` pairs.
`--flag` (no `=`) stores `"true"`.  Short `-x` stores `"true"` under `"x"`.
"""
function _parse_flags(args::AbstractVector{<:AbstractString})
    flags = Dict{String,String}()
    pos   = String[]
    for a in args
        if startswith(a, "--")
            eq = findfirst('=', a)
            if eq !== nothing
                flags[a[3:eq-1]] = a[eq+1:end]
            else
                flags[a[3:end]] = "true"
            end
        elseif length(a) == 2 && a[1] == '-'
            flags[string(a[2])] = "true"
        else
            push!(pos, a)
        end
    end
    pos, flags
end

_bool_flag(flags, key) = get(flags, key, "false") == "true"

# ── Subcommands ───────────────────────────────────────────────────────────────

function _cmd_build(args::AbstractVector{<:AbstractString})::Cint
    pos, flags = _parse_flags(args)
    if isempty(pos) || _bool_flag(flags, "help") || _bool_flag(flags, "h")
        println("usage: pt build FILE.jl [--outdir=DIR] [--mod-name=NAME] ",
                "[--trim=safe|unsafe] [--abi3] [--verbose]")
        return isempty(pos) ? 1 : 0
    end
    file    = pos[1]
    length(pos) > 1 && @warn "pt build: extra arguments ignored" extra=pos[2:end]
    outdir  = get(flags, "outdir", dirname(abspath(file)))
    mod     = get(flags, "mod-name", nothing)
    trim    = Symbol(get(flags, "trim", "safe"))
    abi3    = _bool_flag(flags, "abi3")
    verbose = _bool_flag(flags, "verbose")
    so = build_extension(file; outdir, mod_name=mod, trim, abi3, verbose)
    println("Built: ", so)
    return 0
end

function _cmd_wheel(args::AbstractVector{<:AbstractString})::Cint
    pos, flags = _parse_flags(args)
    if isempty(pos) || _bool_flag(flags, "help") || _bool_flag(flags, "h")
        println("usage: pt wheel FILE.jl [--outdir=dist] [--version=0.1.0] ",
                "[--mod-name=NAME] [--trim=safe|unsafe] ",
                "[--manylinux=2.17|false] [--runtime=bundled|shared|system] ",
                "[--slim] [--verbose]")
        return isempty(pos) ? 1 : 0
    end
    file      = pos[1]
    outdir    = get(flags, "outdir", "dist")
    version   = get(flags, "version", "0.1.0")
    mod       = get(flags, "mod-name", nothing)
    trim      = Symbol(get(flags, "trim", "safe"))
    ml_raw    = get(flags, "manylinux", "true")
    manylinux = ml_raw == "false" ? false : ml_raw == "true" ? true : ml_raw
    runtime   = Symbol(get(flags, "runtime", "bundled"))
    slim      = _bool_flag(flags, "slim")
    verbose   = _bool_flag(flags, "verbose")
    whl = build_wheel(file; outdir, version, mod_name=mod, trim, manylinux, runtime, slim, verbose)
    println("Built: ", whl)
    return 0
end

function _cmd_bench(args::AbstractVector{<:AbstractString})::Cint
    pos, flags = _parse_flags(args)
    if isempty(pos) || _bool_flag(flags, "help") || _bool_flag(flags, "h")
        println("usage: pt bench EXT.so [--call=EXPR] [--n=N]")
        return isempty(pos) ? 1 : 0
    end
    ext_path  = pos[1]
    call_expr = get(flags, "call", nothing)
    n         = parse(Int, get(flags, "n", "5"))
    r = startup_benchmark(ext_path; call_expr, n)
    println("import  median=", round(r.import_ms_median; digits=1), "ms  ",
            "min=", round(r.import_ms_min; digits=1), "  ",
            "max=", round(r.import_ms_max; digits=1))
    if r.call_ms_median !== nothing
        println("call    median=", round(r.call_ms_median; digits=3), "ms  ",
                "min=", round(r.call_ms_min; digits=3), "  ",
                "max=", round(r.call_ms_max; digits=3))
    end
    return 0
end

# ── Entry point ───────────────────────────────────────────────────────────────
# Called by `julia -m ParselTongue [args]` (Pkg Apps) and by app/pt.jl (juliac binary).

function julia_main()::Cint
    isempty(ARGS) && (print(_USAGE); return 0)
    cmd  = ARGS[1]
    rest = ARGS[2:end]
    try
        if cmd == "build"
            return _cmd_build(rest)
        elseif cmd == "wheel"
            return _cmd_wheel(rest)
        elseif cmd == "bench"
            return _cmd_bench(rest)
        elseif cmd in ("version", "--version", "-V")
            println("pt $_PT_CLI_VERSION (ParselTongue.jl)")
            return 0
        elseif cmd in ("help", "--help", "-h")
            print(_USAGE)
            return 0
        else
            println(stderr, "pt: unknown command '$cmd'\n")
            print(stderr, _USAGE)
            return 1
        end
    catch e
        println(stderr, "pt: error: ", sprint(showerror, e))
        return 1
    end
end
