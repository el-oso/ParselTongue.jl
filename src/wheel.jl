# ── Self-contained wheel packaging ────────────────────────────────────
#
# build_wheel produces a pip-installable wheel that bundles the trimmed
# extension AND the Julia runtime, so it imports on a machine with no Julia
# installed. Layout (package `mymod`):
#
#   mymod/__init__.py                       re-exports the compiled extension
#   mymod/_mymod.<EXT_SUFFIX>               the extension (PyInit__mymod)
#   mymod/julia/lib/libjulia.so.1.x         \ original relative layout preserved
#   mymod/julia/lib/julia/libjulia-internal…/  so the bundled libs resolve each
#   mymod/julia/lib/julia/{libunwind,…}     / other via their existing RUNPATHs
#   mymod-<ver>.dist-info/{METADATA,WHEEL,RECORD}
#
# The extension is linked with rpath `$ORIGIN/julia/lib` and
# `$ORIGIN/julia/lib/julia`, with the absolute juliaup rpaths stripped (D3).

# Libraries to omit from the bundle: only what a `--trim`ed AOT binary provably
# never needs — the system image (the trimmed img.a replaces it), the LLVM JIT,
# and codegen (no runtime compilation under trim), plus build test libs. Dropping
# these saves ~500 MB. We must KEEP the stdlib backends (OpenBLAS, SuiteSparse,
# networking): the trimmed runtime runs their JLL `__init__`s at startup, which
# *fatally* dlopen those libraries even when the user's code never uses them.
# (A future optimisation would suppress those unused inits and shrink the bundle.)
const _SKIP_LIB = r"^(sys\.so|libLLVM|libjulia-codegen|libccalltest|libllvmcalltest|libccalllazybar)"

# Copy every `*.so*` entry in `srcdir` (skipping `_SKIP_LIB`) into `dstdir`,
# preserving symlink chains so any soname (versioned or not) resolves.
function _vendor_libs(srcdir::AbstractString, dstdir::AbstractString)
    mkpath(dstdir)
    n = 0
    for name in readdir(srcdir)
        occursin(".so", name) || continue
        occursin(_SKIP_LIB, name) && continue
        cp(joinpath(srcdir, name), joinpath(dstdir, name);
           follow_symlinks=false, force=true)
        n += 1
    end
    n
end

"""
    build_wheel(user_path; version="0.1.0", mod_name=nothing,
                outdir=dirname(user_path), python="python3", trim=:safe,
                abi3=false, runtime=:bundled, slim=false,
                keep_build=false, verbose=false) -> String

Build a pip-installable wheel from the `@pyfunc`-annotated functions in `user_path`.
Returns the path to the `.whl`.

`runtime` controls how the Julia runtime is distributed:
- `:bundled` (default) — the wheel is self-contained (~100 MB); libjulia and all
  transitive dependencies are vendored inside the wheel. No extra install required.
- `:shared` — the wheel is tiny (~1 MB); the Julia runtime is provided by a separate
  `parseltongue-runtime` wheel. Install that wheel once and share it across many
  extension wheels. The extension's `__init__.py` sets `LD_LIBRARY_PATH` to point at
  the runtime package's `julia/lib` dirs before importing the extension `.so`.
  Build the runtime wheel with [`build_runtime_wheel`](@ref).

When `slim=true` the bundled Julia runtime is trimmed to only the libraries that the
extension `.so` actually needs (via `readelf -d` BFS), reducing wheel size from ~100 MB
to ~38 MB for typical numeric/string extensions. **Warning**: `slim=true` breaks
extensions that `using LinearAlgebra`, `using SuiteSparse`, etc. — those JLL
`__init__`s dlopen their libraries at startup via `dlopen` calls (not DT_NEEDED entries),
so they are absent from the transitive closure and will cause an `ImportError` at
runtime. Only use `slim=true` if you are sure your code does not load stdlib JLLs.

When `abi3=true` the extension is compiled against the stable ABI
(`Py_LIMITED_API=0x030B0000`) and the wheel tag is `cp311-abi3-<plat>`,
making it installable on any CPython ≥ 3.11 without recompilation.
"""
function build_wheel(user_path::AbstractString;
                     version::AbstractString="0.1.0",
                     mod_name::Union{Nothing,AbstractString}=nothing,
                     outdir::AbstractString=dirname(abspath(user_path)),
                     python::AbstractString="python3",
                     trim::Symbol=:safe,
                     abi3::Bool=false,
                     runtime::Symbol=:bundled,
                     slim::Bool=false,
                     keep_build::Bool=false,
                     verbose::Bool=false)
    runtime in (:bundled, :shared) ||
        error("ParselTongue: runtime must be :bundled or :shared, got :$runtime")
    slim && runtime === :shared &&
        error("ParselTongue: slim=true is not meaningful with runtime=:shared (no libs are vendored)")

    user_path = abspath(user_path)
    # Resolve the user-facing module name the same way build_extension does.
    clear_exports!(); _MODULE_NAME[] = nothing
    sandbox = Module(:ParselTongueUserSandbox)
    Core.eval(sandbox, :(using ParselTongue))
    Base.include(sandbox, user_path)
    mod = mod_name !== nothing ? String(mod_name) :
          _MODULE_NAME[] !== nothing ? _MODULE_NAME[] :
          _default_mod_name(user_path)
    _is_valid_modname(mod) || error("ParselTongue: invalid module name '$mod'.")

    mkpath(outdir)
    stage = mktempdir(; prefix="ptwheel_", cleanup=!keep_build)
    pkgdir = joinpath(stage, mod); mkpath(pkgdir)

    # 1. Build the extension as the internal submodule `_<mod>`.
    #    Bundled: embed $ORIGIN rpaths so the .so finds the vendored libs.
    #    Shared: no rpaths; resolution happens via LD_LIBRARY_PATH set at import.
    ext_name = string("_", mod)
    rpaths = runtime === :bundled ?
        ["\$ORIGIN/julia/lib", "\$ORIGIN/julia/lib/julia"] : String[]
    so = build_extension(user_path;
                         mod_name=ext_name, outdir=pkgdir, trim, python, abi3,
                         runtime_rpaths=rpaths,
                         strip_abs_rpath=true, keep_build, verbose)
    exports = copy(_EXPORTS)   # build_extension repopulated the registry

    # 2. Vendor the Julia runtime (bundled only).
    if runtime === :bundled
        libsrc = abspath(joinpath(Sys.BINDIR, "..", "lib"))
        libsrc_julia = joinpath(libsrc, "julia")
        dst_lib      = joinpath(pkgdir, "julia", "lib")
        dst_lib_j    = joinpath(pkgdir, "julia", "lib", "julia")
        if slim
            # BFS over DT_NEEDED from the compiled .so; only vendor what's reachable.
            lib_dirs = [libsrc, libsrc_julia]
            needed   = _transitive_needed(so, lib_dirs)
            verbose && @info "ParselTongue: slim=true — vendoring $(length(needed)) libs (of $(length(readdir(libsrc_julia))) total)"
            _vendor_libs_smart(libsrc,       dst_lib,   needed)
            _vendor_libs_smart(libsrc_julia, dst_lib_j, needed)
        else
            _vendor_libs(libsrc,       dst_lib)
            _vendor_libs(libsrc_julia, dst_lib_j)
        end
    end

    # 3. __init__.py + per-submodule re-export files.
    if runtime === :bundled
        _write_pkg_pyfiles(pkgdir, ext_name, exports)
    else
        _write_shared_pkg_pyfiles(pkgdir, ext_name, exports, mod)
    end

    # 4. dist-info metadata.
    julia_major_minor = join(split(_julia_version_str(), '.')[1:2], '.')
    runtime_req = runtime === :shared ?
        "parseltongue-runtime ~= $(julia_major_minor).0" : nothing
    distinfo = joinpath(stage, string(mod, "-", version, ".dist-info")); mkpath(distinfo)
    tag = abi3 ? _wheel_tag_abi3(python) : _wheel_tag(python)
    write(joinpath(distinfo, "METADATA"), _metadata(mod, version; runtime_requires=runtime_req))
    write(joinpath(distinfo, "WHEEL"), _wheel_meta(tag))

    # 5. Zip the tree into a .whl (Python helper computes RECORD hashes + zips).
    whl_name = string(mod, "-", version, "-", tag, ".whl")
    whl_path = joinpath(abspath(outdir), whl_name)
    _pack_wheel(python, stage, whl_path, string(mod, "-", version, ".dist-info"))
    verbose && @info "ParselTongue: built wheel $whl_path (runtime=$runtime)"
    return whl_path
end

# Write `__init__.py` plus one `<sub>.py` per submodule, all re-exporting from the
# single compiled extension `ext_name` (which holds every function). Top-level
# functions (no submodule) are exposed on the package itself.
function _write_pkg_pyfiles(pkgdir::AbstractString, ext_name::AbstractString,
                            exports::AbstractVector{PtExport})
    subs = submodule_names(exports)
    toplevel = [e.export_name for e in exports if isempty(e.submodule)]

    io = IOBuffer()
    println(io, "\"\"\"Built with ParselTongue (juliac --trim).\"\"\"")
    isempty(toplevel) || println(io, "from .", ext_name, " import (", join(toplevel, ", "), ")")
    for s in subs
        println(io, "from . import ", s, "  # noqa: F401")
    end
    allnames = vcat(toplevel, subs)
    println(io, "__all__ = [", join(("\"$n\"" for n in allnames), ", "), "]")
    write(joinpath(pkgdir, "__init__.py"), String(take!(io)))

    for s in subs
        names = [e.export_name for e in exports if e.submodule == s]
        write(joinpath(pkgdir, string(s, ".py")),
              string("\"\"\"", s, " submodule.\"\"\"\n",
                     "from .", ext_name, " import (", join(names, ", "), ")\n",
                     "__all__ = [", join(("\"$n\"" for n in names), ", "), "]\n"))
    end
    return nothing
end

function _metadata(mod, version; runtime_requires::Union{Nothing,AbstractString}=nothing)
    io = IOBuffer()
    println(io, "Metadata-Version: 2.1")
    println(io, "Name: $mod")
    println(io, "Version: $version")
    println(io, "Summary: $mod — Julia functions compiled to a native Python extension via ParselTongue")
    println(io, "Provides-Extra: numpy")
    println(io, "Requires-Dist: numpy; extra == \"numpy\"")
    runtime_requires !== nothing && println(io, "Requires-Dist: $runtime_requires")
    return String(take!(io))
end

const _PT_VERSION = string(pkgversion(@__MODULE__))

_wheel_meta(tag) = "Wheel-Version: 1.0\nGenerator: ParselTongue ($(_PT_VERSION))\nRoot-Is-Purelib: false\nTag: $tag\n"

# CPython wheel compatibility tag, e.g. "cp314-cp314-linux_x86_64".
function _wheel_tag(python::AbstractString)
    out = readchomp(`$python -c "import sysconfig,sys;v=sys.version_info;print(f'cp{v.major}{v.minor}-cp{v.major}{v.minor}-'+sysconfig.get_platform().replace('-','_').replace('.','_'))"`)
    return out
end

# Stable-ABI wheel tag, e.g. "cp311-abi3-linux_x86_64".
function _wheel_tag_abi3(python::AbstractString)
    plat = readchomp(`$python -c "import sysconfig; print(sysconfig.get_platform().replace('-','_').replace('.','_'))"`)
    return "cp311-abi3-$plat"
end

# Generate + run a Python helper that writes RECORD (with sha256) and zips the
# staging dir into the wheel. Done in Python so ParselTongue needs no SHA/zip
# deps (which would otherwise enter the juliac --trim graph).
function _pack_wheel(python::AbstractString, stage::AbstractString,
                     whl_path::AbstractString, distinfo_name::AbstractString)
    helper = joinpath(stage, "_pt_pack.py")
    write(helper, _PACK_PY)
    if !success(pipeline(`$python $helper $stage $whl_path $distinfo_name`; stdout, stderr))
        error("ParselTongue: wheel packaging (zip/RECORD) failed.")
    end
    isfile(whl_path) || error("ParselTongue: wheel was not produced at $whl_path.")
    return whl_path
end

const _PACK_PY = raw"""
import base64, hashlib, os, sys, zipfile

stage, whl_path, distinfo = sys.argv[1], sys.argv[2], sys.argv[3]

def files(root):
    for dp, _, fns in os.walk(root):
        for fn in fns:
            full = os.path.join(dp, fn)
            if full == whl_path:
                continue
            yield full, os.path.relpath(full, root)

records = []
with zipfile.ZipFile(whl_path, "w", zipfile.ZIP_DEFLATED) as z:
    for full, rel in files(stage):
        arc = rel.replace(os.sep, "/")
        if arc.endswith("_pt_pack.py"):
            continue
        data = open(full, "rb").read()
        z.write(full, arc)
        h = base64.urlsafe_b64encode(hashlib.sha256(data).digest()).rstrip(b"=").decode()
        records.append((arc, f"sha256={h}", str(len(data))))
    record_arc = distinfo + "/RECORD"
    lines = [f"{a},{h},{s}" for a, h, s in records]
    lines.append(f"{record_arc},,")
    z.writestr(record_arc, "\n".join(lines) + "\n")
print(whl_path)
"""

# ── Shared-runtime support ─────────────────────────────────────────────

_julia_version_str() = string(VERSION)

# Runtime wheel tag: "py3-none-linux_x86_64" (any Python 3, platform-specific).
function _runtime_wheel_tag(python::AbstractString)
    plat = readchomp(`$python -c "import sysconfig; print(sysconfig.get_platform().replace('-','_').replace('.','_'))"`)
    return "py3-none-$plat"
end

# __init__.py for the parseltongue_runtime package: exposes the lib path constants
# so extension __init__.py files can locate Julia libs without hard-coding paths.
const _RUNTIME_INIT_PY = """\"\"\"Julia runtime libraries for ParselTongue extension wheels.

This package vendors libjulia and its transitive dependencies. Extension wheels
built with build_wheel(...; runtime=:shared) set LD_LIBRARY_PATH to point at
the julia/lib directories here before importing their compiled extension .so.
\"\"\"
import os as _os
_JULIA_LIB = _os.path.join(_os.path.dirname(__file__), "julia", "lib")
_JULIA_LIB_JULIA = _os.path.join(_JULIA_LIB, "julia")
"""

function _runtime_metadata(version::AbstractString, julia_version::AbstractString)
    io = IOBuffer()
    println(io, "Metadata-Version: 2.1")
    println(io, "Name: parseltongue-runtime")
    println(io, "Version: $version")
    println(io, "Summary: Julia runtime libraries for ParselTongue extension wheels (Julia $julia_version)")
    return String(take!(io))
end

"""
    build_runtime_wheel(; version=nothing, outdir=".", python="python3", verbose=false) -> String

Build a platform-specific wheel that vendors the Julia runtime (`libjulia` and all
transitive native dependencies). Extension wheels built with
`build_wheel(...; runtime=:shared)` declare a `Requires-Dist: parseltongue-runtime`
dependency on this wheel, keeping the extension wheel small (~1 MB vs ~100 MB).

The wheel is tagged `py3-none-<plat>` (any Python 3, platform-specific). `version`
defaults to the current Julia version string (e.g. `"1.12.6"`).

Install the runtime wheel once and share it across many extension wheels built from
the same Julia installation:
```
julia -e 'using ParselTongue; build_runtime_wheel(outdir="dist")'
julia -e 'using ParselTongue; build_wheel("ext.jl"; runtime=:shared, outdir="dist")'
pip install dist/parseltongue_runtime-*.whl dist/ext-*.whl
```
"""
function build_runtime_wheel(;
        version::Union{Nothing,AbstractString}=nothing,
        outdir::AbstractString=".",
        python::AbstractString="python3",
        verbose::Bool=false)
    julia_ver = _julia_version_str()
    ver = version !== nothing ? String(version) : julia_ver
    mod = "parseltongue_runtime"

    stage = mktempdir(; prefix="ptruntime_", cleanup=true)
    pkgdir = joinpath(stage, mod); mkpath(pkgdir)

    libsrc = abspath(joinpath(Sys.BINDIR, "..", "lib"))
    _vendor_libs(libsrc, joinpath(pkgdir, "julia", "lib"))
    _vendor_libs(joinpath(libsrc, "julia"), joinpath(pkgdir, "julia", "lib", "julia"))

    write(joinpath(pkgdir, "__init__.py"), _RUNTIME_INIT_PY)

    tag = _runtime_wheel_tag(python)
    distinfo = joinpath(stage, string(mod, "-", ver, ".dist-info")); mkpath(distinfo)
    write(joinpath(distinfo, "METADATA"), _runtime_metadata(ver, julia_ver))
    write(joinpath(distinfo, "WHEEL"), _wheel_meta(tag))

    mkpath(outdir)
    whl_name = string(mod, "-", ver, "-", tag, ".whl")
    whl_path = joinpath(abspath(outdir), whl_name)
    _pack_wheel(python, stage, whl_path, string(mod, "-", ver, ".dist-info"))
    verbose && @info "ParselTongue: built runtime wheel $whl_path"
    return whl_path
end

# Write __init__.py for a shared-runtime extension wheel: sets LD_LIBRARY_PATH
# to point at parseltongue_runtime's julia/lib dirs before importing the .so.
function _write_shared_pkg_pyfiles(pkgdir::AbstractString, ext_name::AbstractString,
                                   exports::AbstractVector{PtExport}, mod::AbstractString)
    subs = submodule_names(exports)
    toplevel = [e.export_name for e in exports if isempty(e.submodule)]
    allnames = vcat(toplevel, subs)

    imports_str = isempty(toplevel) ? "" :
        "from .$ext_name import ($(join(toplevel, ", ")))\n"
    submod_str = join(("from . import $s  # noqa: F401\n" for s in subs), "")
    all_str = "__all__ = [$(join(("\"$n\"" for n in allnames), ", "))]\n"

    # Python uses single-quoted strings to avoid Julia/Python double-quote conflicts.
    # LD_LIBRARY_PATH is set before the extension import so glibc re-reads it at dlopen.
    init_py = """
\"\"\"$mod — built with ParselTongue. Requires parseltongue-runtime.\"\"\"
import importlib.util as _ilu, os as _os
def _preload():
    _s = _ilu.find_spec('parseltongue_runtime')
    if _s is None:
        raise ImportError(
            '$mod requires parseltongue-runtime. Install with:\\n'
            '  pip install parseltongue-runtime'
        )
    _rt = _os.path.dirname(_s.origin)
    _l1 = _os.path.join(_rt, 'julia', 'lib')
    _l2 = _os.path.join(_rt, 'julia', 'lib', 'julia')
    _prev = _os.environ.get('LD_LIBRARY_PATH', '')
    _os.environ['LD_LIBRARY_PATH'] = ':'.join(x for x in (_l1, _l2, _prev) if x)
_preload()
del _preload, _ilu, _os
$(imports_str)$(submod_str)$(all_str)"""

    write(joinpath(pkgdir, "__init__.py"), lstrip(init_py))

    for s in subs
        names = [e.export_name for e in exports if e.submodule == s]
        write(joinpath(pkgdir, string(s, ".py")),
              string("\"\"\"", s, " submodule.\"\"\"\n",
                     "from .", ext_name, " import (", join(names, ", "), ")\n",
                     "__all__ = [", join(("\"$n\"" for n in names), ", "), "]\n"))
    end
    return nothing
end

# ── Slim vendoring (item 9) ────────────────────────────────────────────

# Return the DT_NEEDED sonames listed in `so_path` (requires `readelf` on PATH).
function _readelf_needed(so_path::AbstractString)
    needed = String[]
    for line in eachline(ignorestatus(`readelf -d $so_path`))
        m = match(r"\(NEEDED\)\s+Shared library: \[([^\]]+)\]", line)
        m !== nothing && push!(needed, m.captures[1])
    end
    return needed
end

# Resolve a soname to an on-disk path by searching `lib_dirs` in order.
# Returns `nothing` if not found in any of the search dirs.
function _resolve_soname(soname::AbstractString, lib_dirs::AbstractVector{<:AbstractString})
    for dir in lib_dirs
        for name in readdir(dir)
            if name == soname
                full = joinpath(dir, name)
                isfile(full) && return full
            end
        end
    end
    return nothing
end

# BFS over DT_NEEDED entries starting from `so_path`; returns the set of sonames
# (basenames) of every transitively needed library found in `lib_dirs`.
function _transitive_needed(so_path::AbstractString,
                            lib_dirs::AbstractVector{<:AbstractString})
    visited  = Set{String}()  # sonames already enqueued
    needed   = Set{String}()  # sonames resolved to a local file
    queue    = String[so_path]

    while !isempty(queue)
        path = popfirst!(queue)
        for soname in _readelf_needed(path)
            soname in visited && continue
            push!(visited, soname)
            resolved = _resolve_soname(soname, lib_dirs)
            resolved === nothing && continue   # system lib — not vendored
            push!(needed, soname)
            push!(queue, resolved)
        end
    end
    return needed
end

# Like _vendor_libs but only copies libs whose soname (or the soname of their
# symlink target) appears in `needed`.
function _vendor_libs_smart(srcdir::AbstractString, dstdir::AbstractString,
                            needed::Set{String})
    mkpath(dstdir)
    n = 0
    for name in readdir(srcdir)
        occursin(".so", name) || continue
        occursin(_SKIP_LIB, name) && continue
        path = joinpath(srcdir, name)
        real_name = islink(path) ? basename(realpath(path)) : name
        (name in needed || real_name in needed) || continue
        cp(path, joinpath(dstdir, name); follow_symlinks=false, force=true)
        n += 1
    end
    n
end

"""
    bundle_size_report(whl_path; python="python3") -> Vector{NamedTuple}

Return a list of `(; name, bytes, compressed_bytes)` NamedTuples for every file
in `whl_path`, sorted largest uncompressed first. Useful for auditing wheel size.

```julia-repl
julia> rpt = bundle_size_report("dist/mathx-0.1.0-cp314-cp314-linux_x86_64.whl")
julia> foreach(r -> println(lpad(r.bytes ÷ 1024, 8), " KB  ", r.name), rpt[1:10])
```
"""
function bundle_size_report(whl_path::AbstractString;
                            python::AbstractString=get(ENV, "PYTHON3", "python3"))
    script = raw"""
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    for i in sorted(z.infolist(), key=lambda x: -x.file_size):
        print(f"{i.file_size}\t{i.compress_size}\t{i.filename}")
"""
    lines = readlines(`$python -c $script $whl_path`)
    T = @NamedTuple{name::String, bytes::Int, compressed_bytes::Int}
    result = T[]
    for line in lines
        parts = split(line, '\t'; limit=3)
        length(parts) == 3 || continue
        push!(result, (name=String(parts[3]),
                       bytes=parse(Int, parts[1]),
                       compressed_bytes=parse(Int, parts[2])))
    end
    return result
end
