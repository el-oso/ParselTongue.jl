using Test
using ParselTongue

# Guarantee that the code printed in the docs Examples pages actually works: for
# each page we extract its ```julia blocks (which concatenate, in page order, into
# one complete module file), build it with juliac --trim=safe, then feed the page's
# ```python `>>>` blocks to Python's `doctest` so the *shown outputs are verified*.
# A page is the single source of truth — what a user copies is exactly what is tested.
#
# Most pages build a flat module (mode :ext — build_extension + import the .so).
# Submodule pages (e.g. `@pymodule sci.linalg`) need the package wrapper, so they
# use mode :wheel — build_wheel(runtime=:system) + extract + import the package.

const _DOC_EXAMPLES = [
    ("scalars.md",          "mathx",  :ext),
    ("strings.md",          "strx",   :ext),
    ("arrays.md",           "arrx",   :ext),
    ("classes.md",          "shapes", :ext),
    ("callbacks-errors.md", "numkit", :ext),
    ("statistics.md",       "stats",  :ext),
    ("scientific.md",       "sci",    :wheel),
]

_docs_dir() = normpath(joinpath(@__DIR__, "..", "docs", "src", "examples"))

# Extract the bodies of all ```<lang> … ``` fenced blocks, in document order.
function _fenced_blocks(md::AbstractString, lang::AbstractString)
    blocks = String[]
    for m in eachmatch(Regex("```" * lang * "\\n(.*?)\\n```", "s"), md)
        push!(blocks, String(m.captures[1]))
    end
    return blocks
end

function _docs_have_tools()
    Sys.which("python3") !== nothing || return false
    (Sys.which("cc") !== nothing || Sys.which("gcc") !== nothing) || return false
    bs = joinpath(Sys.BINDIR, Base.DATAROOTDIR, "julia", "juliac", "juliac-buildscript.jl")
    return isfile(bs)
end

# Run a python script, returning (ok, combined_output).
function _docs_py(script::AbstractString, env::Pair...)
    py = Sys.which("python3")
    buf = IOBuffer()
    base = ["HOME" => get(ENV, "HOME", ""), "PATH" => get(ENV, "PATH", "/usr/bin:/bin")]
    ok = try
        run(pipeline(setenv(`$py -c $script`, base..., env...), stdout=buf, stderr=buf))
        true
    catch
        false
    end
    return ok, String(take!(buf))
end

@testset "docs examples build + doctest ($(page))" for (page, modname, mode) in _DOC_EXAMPLES
    md = read(joinpath(_docs_dir(), page), String)
    # Module-definition blocks only: skip the "build it" instruction blocks.
    jl_blocks = filter(_fenced_blocks(md, "julia")) do b
        !occursin("build_wheel(", b) && !occursin("build_extension(", b)
    end
    py_blocks = filter(b -> occursin(">>>", b), _fenced_blocks(md, "python"))
    @test !isempty(jl_blocks)   # the page defines a module
    @test !isempty(py_blocks)   # the page shows usage

    if !_docs_have_tools()
        @info "skipping docs-example build/doctest for $page (need python3, a C compiler, and juliac)"
        @test_skip true
        continue
    end

    outdir = mktempdir()
    src = joinpath(outdir, modname * ".jl")
    write(src, join(jl_blocks, "\n\n"))

    # Build, and determine where the module/package is importable from + any env.
    local import_dir::String
    env = Pair{String,String}[]
    if mode === :wheel
        whl = build_wheel(src; runtime=:system, outdir=outdir, version="0.1.0")
        @test isfile(whl)
        import_dir = joinpath(outdir, "x")
        ok, _ = _docs_py("import zipfile; zipfile.ZipFile($(repr(whl))).extractall($(repr(import_dir)))")
        @test ok
        push!(env, "JULIA_BINDIR" => Sys.BINDIR)   # :system runtime locates libjulia here
    else
        so = build_extension(src; outdir=outdir)   # trim=safe by default
        @test isfile(so)
        import_dir = outdir
    end

    if Sys.iswindows()
        # Bare-extension DLLs aren't resolvable without a wheel/env on Windows; the
        # trim-safe build above is the portable guarantee here.
        @info "Windows: $page built (doctest is import-dependent — run via a wheel)"
        continue
    end

    # Feed the page's `>>>` transcript to doctest, with the built module importable.
    write(joinpath(outdir, "doc.txt"), join(py_blocks, "\n\n"))
    script = """
    import sys, doctest, os
    sys.path.insert(0, $(repr(import_dir)))
    r = doctest.testfile(os.path.join($(repr(outdir)), "doc.txt"),
                         module_relative=False, optionflags=doctest.ELLIPSIS)
    print("DOCTEST attempted", r.attempted, "failed", r.failed)
    sys.exit(0 if r.failed == 0 else 1)
    """
    ok, out = _docs_py(script, env...)
    @test ok || error("doctest failures in $page:\n$out")
    @test occursin("failed 0", out)
    @info "docs example $page: $(strip(out))"
end
