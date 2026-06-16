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
# Matches both Linux (.so) and macOS (.dylib) variants of libs we never bundle.
const _SKIP_LIB = r"^(sys\.(so|dylib|dll)|libLLVM|libjulia-codegen|libccalltest|libllvmcalltest|libccalllazybar)"

_is_dynlib(name::AbstractString) =
    occursin(".so", name) || occursin(".dylib", name) || endswith(name, ".dll")

# Current OS identifier used to select __init__.py preload strategy.
# Parameterisable so tests can exercise non-host branches without a real Windows build.
_current_os_kernel() = Sys.iswindows() ? :windows : Sys.isapple() ? :apple : :linux

# Copy every .dll in Julia's bin/ directory (Windows) into `dstdir`.
function _vendor_libs_win(srcdir::AbstractString, dstdir::AbstractString)
    mkpath(dstdir)
    n = 0
    for name in readdir(srcdir)
        endswith(name, ".dll") || continue
        occursin(_SKIP_LIB, name) && continue
        cp(joinpath(srcdir, name), joinpath(dstdir, name); follow_symlinks=false, force=true)
        n += 1
    end
    n
end

# Copy every shared-library entry in `srcdir` (skipping `_SKIP_LIB`) into `dstdir`,
# preserving symlink chains so any soname/install-name resolves.
function _vendor_libs(srcdir::AbstractString, dstdir::AbstractString)
    mkpath(dstdir)
    n = 0
    for name in readdir(srcdir)
        _is_dynlib(name) || continue
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
- `:system` — the wheel is tiny (~1 MB) and has no runtime dependency; the extension
  locates Julia at import time via `JULIA_BINDIR` or `JULIA_PREFIX` environment
  variables, or by querying `julia` on `PATH`. **Requires Julia ≥ 1.12 to be
  installed on the target machine.** Suitable for teams that already use Julia
  alongside Python.

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

`manylinux` controls the Linux platform tag (ignored on macOS/Windows):
- `true` (default) — auto-detect glibc from the build host via `platform.libc_ver()`.
- `"2.17"` — pin to manylinux_2_17 (the Julia 1.12+ / manylinux2014 floor; recommended
  for wheels intended for PyPI, since Julia 1.12 itself targets glibc ≥ 2.17).
- `false` — raw `linux_x86_64` tag (local use only; not accepted by PyPI).
"""
function build_wheel(user_path::AbstractString;
                     version::AbstractString="0.1.0",
                     mod_name::Union{Nothing,AbstractString}=nothing,
                     outdir::AbstractString=dirname(abspath(user_path)),
                     python::AbstractString="python3",
                     trim::Symbol=:safe,
                     abi3::Bool=false,
                     manylinux::Union{Bool,AbstractString}=true,
                     runtime::Symbol=:bundled,
                     slim::Bool=false,
                     keep_build::Bool=false,
                     verbose::Bool=false)
    runtime in (:bundled, :shared, :system) ||
        error("ParselTongue: runtime must be :bundled, :shared, or :system, got :$runtime")
    slim && runtime !== :bundled &&
        error("ParselTongue: slim=true is not meaningful with runtime=:$runtime (no libs are vendored)")

    user_path = abspath(user_path)
    # Include the user source once to resolve the module name and populate the export
    # registry.  The result is passed to build_extension as _preloaded to skip a
    # redundant second include.
    clear_exports!(); _MODULE_NAME[] = nothing
    sandbox = Module(:ParselTongueUserSandbox)
    Core.eval(sandbox, :(using ParselTongue))
    Base.include(sandbox, user_path)
    mod = mod_name !== nothing ? String(mod_name) :
          _MODULE_NAME[] !== nothing ? _MODULE_NAME[] :
          _default_mod_name(user_path)
    _is_valid_modname(mod) || error("ParselTongue: invalid module name '$mod'.")
    preloaded    = (copy(_EXPORTS), copy(_ERRORS), copy(_HANDLE_TYPES))
    exports      = preloaded[1]
    handle_types = preloaded[3]

    mkpath(outdir)
    stage = mktempdir(; prefix="ptwheel_", cleanup=!keep_build)
    pkgdir = joinpath(stage, mod); mkpath(pkgdir)

    # 1. Build the extension as the internal submodule `_<mod>`.
    #    Bundled: embed relative rpaths so the .so finds the vendored libs.
    #      Linux: $ORIGIN (re-read per dlopen); macOS: @loader_path (resolved by dyld).
    #      Windows: no rpaths — DLLs found via add_dll_directory in __init__.py.
    #    Shared/System: no rpaths; resolution happens via preloading at import time.
    ext_name = string("_", mod)
    origin = Sys.isapple() ? "@loader_path" : "\$ORIGIN"
    rpaths = (runtime === :bundled && !Sys.iswindows()) ?
        ["$origin/julia/lib", "$origin/julia/lib/julia"] : String[]
    so = build_extension(user_path;
                         mod_name=ext_name, outdir=pkgdir, trim, python, abi3,
                         runtime_rpaths=rpaths,
                         strip_abs_rpath=true, keep_build, verbose,
                         _preloaded=preloaded)

    # 2. Vendor the Julia runtime (bundled only).
    if runtime === :bundled
        if Sys.iswindows()
            # On Windows, Julia DLLs live in bin/ (not lib/).
            binsrc  = String(Sys.BINDIR)
            dst_bin = joinpath(pkgdir, "julia", "bin")
            if slim
                needed = _transitive_needed(so, [binsrc])
                verbose && @info "ParselTongue: slim=true — vendoring $(length(needed)) DLLs"
                _vendor_libs_smart(binsrc, dst_bin, needed)
            else
                _vendor_libs_win(binsrc, dst_bin)
            end
        else
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
    end

    os_k = _current_os_kernel()
    # 3. __init__.py + per-submodule re-export files.
    if runtime === :bundled
        _write_pkg_pyfiles(pkgdir, ext_name, exports, handle_types; _os_kernel=os_k)
    elseif runtime === :shared
        _write_shared_pkg_pyfiles(pkgdir, ext_name, exports, mod, handle_types; _os_kernel=os_k)
    else  # :system
        _write_system_pkg_pyfiles(pkgdir, ext_name, exports, mod, handle_types; _os_kernel=os_k)
    end

    # 4. dist-info metadata.
    # ~= X.Y.0 is derived from VERSION string; pre-release Julia (e.g. 1.13.0-DEV)
    # will produce a pin that pip cannot match against a dev parseltongue-runtime.
    julia_major_minor = join(split(_julia_version_str(), '.')[1:2], '.')
    runtime_req = runtime === :shared ?
        "parseltongue-runtime ~= $(julia_major_minor).0" : nothing
    distinfo = joinpath(stage, string(mod, "-", version, ".dist-info")); mkpath(distinfo)
    tag = abi3 ? _wheel_tag_abi3(python; manylinux) : _wheel_tag(python; manylinux)
    write(joinpath(distinfo, "METADATA"), _metadata(mod, version; runtime_requires=runtime_req))
    write(joinpath(distinfo, "WHEEL"), _wheel_meta(tag))

    # 5. Zip the tree into a .whl (Python helper computes RECORD hashes + zips).
    whl_name = string(mod, "-", version, "-", tag, ".whl")
    whl_path = joinpath(abspath(outdir), whl_name)
    _pack_wheel(python, stage, whl_path, string(mod, "-", version, ".dist-info"))
    verbose && @info "ParselTongue: built wheel $whl_path (runtime=$runtime, size=$(stat(whl_path).size÷1024) KB)"
    return whl_path
end

# Write `__init__.py` plus one `<sub>.py` per submodule, all re-exporting from the
# single compiled extension `ext_name` (which holds every function). Top-level
# functions (no submodule) are exposed on the package itself.
function _write_pkg_pyfiles(pkgdir::AbstractString, ext_name::AbstractString,
                            exports::AbstractVector{PtExport},
                            handle_types::AbstractVector{<:Type}=Type[];
                            _os_kernel::Symbol=_current_os_kernel())
    subs = submodule_names(exports)
    handle_names = [string(T.name.name) for T in handle_types]
    toplevel = vcat([e.export_name for e in exports if isempty(e.submodule)], handle_names)

    io = IOBuffer()
    println(io, "\"\"\"Built with ParselTongue (juliac --trim).\"\"\"")
    if _os_kernel === :windows
        # On Windows, $ORIGIN rpaths don't exist. Add the bundled julia/bin to the
        # DLL search path before importing the extension so libjulia*.dll is found.
        println(io, "import os as _os")
        println(io, "_d = _os.path.dirname(_os.path.abspath(__file__))")
        println(io, "_bin = _os.path.join(_d, 'julia', 'bin')")
        println(io, "if hasattr(_os, 'add_dll_directory'):")
        println(io, "    _os.add_dll_directory(_bin)")
        println(io, "else:")
        println(io, "    _os.environ['PATH'] = _bin + ';' + _os.environ.get('PATH', '')")
        println(io, "del _os, _d, _bin")
    end
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

"""
    _manylinux_plat(python; manylinux=true) -> String

Return the platform tag for the build host, with manylinux substitution on Linux.

- `manylinux=true`  — auto-detect glibc from the build system via `platform.libc_ver()`,
  e.g. `manylinux_2_35_x86_64`. Use when you want a conservative (build-host) floor.
- `manylinux="2.17"` — pin to a specific glibc floor, e.g. `manylinux_2_17_x86_64`.
  Correct for Julia 1.12+, which targets the manylinux2014 (glibc ≥ 2.17) baseline.
- `manylinux=false`  — return the raw platform tag, e.g. `linux_x86_64`. Useful for
  local use; wheels with a plain `linux` tag cannot be uploaded to PyPI.

On non-Linux hosts (macOS, Windows) the `manylinux` argument is ignored.
"""
function _manylinux_plat(python::AbstractString; manylinux::Union{Bool,AbstractString}=true)
    plat = readchomp(`$python -c "import sysconfig; print(sysconfig.get_platform().replace('-','_').replace('.','_'))"`)
    (manylinux === false || !startswith(plat, "linux_")) && return plat
    arch = plat[length("linux_")+1:end]   # e.g. "x86_64", "aarch64"
    if manylinux isa AbstractString
        ver = replace(String(manylinux), "." => "_")   # "2.17" -> "2_17"
        return "manylinux_$(ver)_$arch"
    else
        # Auto-detect the build host's glibc version.
        glibc_ver = readchomp(`$python -c "import platform; l,v=platform.libc_ver(); print(v if l=='glibc' else '')"`)
        isempty(glibc_ver) && return plat   # non-glibc Linux; return unchanged
        ver = replace(glibc_ver, "." => "_")
        return "manylinux_$(ver)_$arch"
    end
end

# CPython wheel compatibility tag, e.g. "cp314-cp314-manylinux_2_35_x86_64".
function _wheel_tag(python::AbstractString; manylinux::Union{Bool,AbstractString}=true)
    plat = _manylinux_plat(python; manylinux)
    pyver = readchomp(`$python -c "import sys; v=sys.version_info; print(f'{v.major}{v.minor}')"`)
    return "cp$(pyver)-cp$(pyver)-$plat"
end

# Stable-ABI wheel tag, e.g. "cp311-abi3-manylinux_2_35_x86_64".
function _wheel_tag_abi3(python::AbstractString; manylinux::Union{Bool,AbstractString}=true)
    plat = _manylinux_plat(python; manylinux)
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

    if Sys.iswindows()
        # On Windows, Julia DLLs are in bin/ rather than lib/ and lib/julia/.
        _vendor_libs_win(String(Sys.BINDIR), joinpath(pkgdir, "julia", "bin"))
    else
        libsrc = abspath(joinpath(Sys.BINDIR, "..", "lib"))
        _vendor_libs(libsrc, joinpath(pkgdir, "julia", "lib"))
        _vendor_libs(joinpath(libsrc, "julia"), joinpath(pkgdir, "julia", "lib", "julia"))
    end

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

# Write __init__.py for a shared-runtime extension wheel.
# Linux: sets LD_LIBRARY_PATH (re-read by glibc at each dlopen).
# macOS: uses ctypes.CDLL to preload Julia dylibs globally before import
#   (DYLD_LIBRARY_PATH is not re-read after process start, so env-var trick fails).
function _write_shared_pkg_pyfiles(pkgdir::AbstractString, ext_name::AbstractString,
                                   exports::AbstractVector{PtExport}, mod::AbstractString,
                                   handle_types::AbstractVector{<:Type}=Type[];
                                   _os_kernel::Symbol=_current_os_kernel())
    subs = submodule_names(exports)
    handle_names = [string(T.name.name) for T in handle_types]
    toplevel = vcat([e.export_name for e in exports if isempty(e.submodule)], handle_names)
    allnames = vcat(toplevel, subs)

    imports_str = isempty(toplevel) ? "" :
        "from .$ext_name import ($(join(toplevel, ", ")))\n"
    submod_str = join(("from . import $s  # noqa: F401\n" for s in subs), "")
    all_str = "__all__ = [$(join(("\"$n\"" for n in allnames), ", "))]\n"

    init_py = if _os_kernel === :windows
        # Windows: parseltongue_runtime vendors DLLs in julia/bin/; add that dir.
        """\"\"\"$mod — built with ParselTongue. Requires parseltongue-runtime.\"\"\"
import importlib.util as _ilu, os as _os
def _preload():
    _s = _ilu.find_spec('parseltongue_runtime')
    if _s is None:
        raise ImportError(
            '$mod requires parseltongue-runtime. Install with:\\n'
            '  pip install parseltongue-runtime'
        )
    _rt = _os.path.dirname(_s.origin)
    _bin = _os.path.join(_rt, 'julia', 'bin')
    if hasattr(_os, 'add_dll_directory'):
        _os.add_dll_directory(_bin)
    else:
        _os.environ['PATH'] = _bin + ';' + _os.environ.get('PATH', '')
_preload()
del _preload, _ilu, _os
$(imports_str)$(submod_str)$(all_str)"""
    else
        preload_body = if _os_kernel === :apple
            # ctypes global-load every *.dylib in the runtime package's lib dirs.
            """    import ctypes as _ct, glob as _gl
    for _lib in sorted(_gl.glob(_os.path.join(_l1, '*.dylib'))) + \\
                sorted(_gl.glob(_os.path.join(_l2, '*.dylib'))):
        try: _ct.CDLL(_lib, _ct.RTLD_GLOBAL)
        except OSError: pass"""
        else
            """    _prev = _os.environ.get('LD_LIBRARY_PATH', '')
    _os.environ['LD_LIBRARY_PATH'] = ':'.join(x for x in (_l1, _l2, _prev) if x)"""
        end
        """\"\"\"$mod — built with ParselTongue. Requires parseltongue-runtime.\"\"\"
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
$preload_body
_preload()
del _preload, _ilu, _os
$(imports_str)$(submod_str)$(all_str)"""
    end

    write(joinpath(pkgdir, "__init__.py"), init_py)

    for s in subs
        names = [e.export_name for e in exports if e.submodule == s]
        write(joinpath(pkgdir, string(s, ".py")),
              string("\"\"\"", s, " submodule.\"\"\"\n",
                     "from .", ext_name, " import (", join(names, ", "), ")\n",
                     "__all__ = [", join(("\"$n\"" for n in names), ", "), "]\n"))
    end
    return nothing
end

# Write __init__.py for a system-runtime extension wheel.
# Locates Julia on the target machine at import time via env vars or PATH.
# Linux: sets LD_LIBRARY_PATH; macOS: ctypes.CDLL preload (same as :shared).
function _write_system_pkg_pyfiles(pkgdir::AbstractString, ext_name::AbstractString,
                                   exports::AbstractVector{PtExport}, mod::AbstractString,
                                   handle_types::AbstractVector{<:Type}=Type[];
                                   _os_kernel::Symbol=_current_os_kernel())
    subs = submodule_names(exports)
    handle_names = [string(T.name.name) for T in handle_types]
    toplevel = vcat([e.export_name for e in exports if isempty(e.submodule)], handle_names)
    allnames = vcat(toplevel, subs)

    imports_str = isempty(toplevel) ? "" :
        "from .$ext_name import ($(join(toplevel, ", ")))\n"
    submod_str = join(("from . import $s  # noqa: F401\n" for s in subs), "")
    all_str = "__all__ = [$(join(("\"$n\"" for n in allnames), ", "))]\n"

    init_py = if _os_kernel === :windows
        # Windows: find Julia's bin/ dir (holds all DLLs) and add it via add_dll_directory.
        """\"\"\"$mod — built with ParselTongue. Requires Julia ≥ 1.12 on the system.\"\"\"
import os as _os, shutil as _sh
def _preload():
    def _find_julia_bin():
        _d = _os.environ.get('JULIA_BINDIR')
        if _d and _os.path.isdir(_d):
            return _d
        _p = _os.environ.get('JULIA_PREFIX')
        if _p and _os.path.isdir(_p):
            return _os.path.join(_p, 'bin')
        _j = _sh.which('julia')
        if _j:
            try:
                import subprocess as _sp
                _d2 = _sp.check_output(
                    [_j, '-e', 'print(Sys.BINDIR)'],
                    stderr=_sp.DEVNULL, timeout=30).decode().strip()
                if _d2:
                    return _d2
            except Exception:
                pass
        raise ImportError(
            '$mod: Julia not found. Set JULIA_BINDIR or JULIA_PREFIX, '
            "or install Julia and add it to PATH. "
            "See https://julialang.org/downloads/")
    _bin = _find_julia_bin()
    if hasattr(_os, 'add_dll_directory'):
        _os.add_dll_directory(_bin)
    else:
        _os.environ['PATH'] = _bin + ';' + _os.environ.get('PATH', '')
_preload()
del _preload, _os, _sh
$(imports_str)$(submod_str)$(all_str)"""
    else
        preload_body = if _os_kernel === :apple
            """    import ctypes as _ct, glob as _gl
    for _lib in sorted(_gl.glob(_os.path.join(_l1, '*.dylib'))) + \\
                sorted(_gl.glob(_os.path.join(_l2, '*.dylib'))):
        try: _ct.CDLL(_lib, _ct.RTLD_GLOBAL)
        except OSError: pass"""
        else
            """    _prev = _os.environ.get('LD_LIBRARY_PATH', '')
    _os.environ['LD_LIBRARY_PATH'] = ':'.join(x for x in (_l1, _l2, _prev) if x)"""
        end
        """\"\"\"$mod — built with ParselTongue. Requires Julia ≥ 1.12 on the system.\"\"\"
import os as _os, shutil as _sh
def _preload():
    def _find_libdirs():
        _d = _os.environ.get('JULIA_BINDIR')
        if _d and _os.path.isdir(_d):
            _b = _os.path.normpath(_os.path.join(_d, '..'))
            return _os.path.join(_b, 'lib'), _os.path.join(_b, 'lib', 'julia')
        _p = _os.environ.get('JULIA_PREFIX')
        if _p and _os.path.isdir(_p):
            return _os.path.join(_p, 'lib'), _os.path.join(_p, 'lib', 'julia')
        _j = _sh.which('julia')
        if _j:
            try:
                import subprocess as _sp
                _d2 = _sp.check_output(
                    [_j, '-e', 'print(Sys.BINDIR)'],
                    stderr=_sp.DEVNULL, timeout=30).decode().strip()
                if _d2:
                    _b = _os.path.normpath(_os.path.join(_d2, '..'))
                    return _os.path.join(_b, 'lib'), _os.path.join(_b, 'lib', 'julia')
            except Exception:
                pass
        raise ImportError(
            '$mod: Julia not found. Set JULIA_BINDIR or JULIA_PREFIX, '
            "or install Julia and add it to PATH. "
            "See https://julialang.org/downloads/")
    _l1, _l2 = _find_libdirs()
$preload_body
_preload()
del _preload, _os, _sh
$(imports_str)$(submod_str)$(all_str)"""
    end

    write(joinpath(pkgdir, "__init__.py"), init_py)

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

# Parse `objdump -p` output for imported DLL names (Windows / MinGW-w64).
# Requires objdump on PATH (present in MinGW-w64 toolchain).
function _objdump_needed(so_path::AbstractString)
    needed = String[]
    for line in eachline(ignorestatus(`objdump -p $so_path`))
        m = match(r"^\s+DLL Name: (.+)$", line)
        m !== nothing && push!(needed, strip(m.captures[1]))
    end
    return needed
end

# Return the DT_NEEDED sonames listed in `so_path` (requires `readelf` on PATH).
function _readelf_needed(so_path::AbstractString)
    needed = String[]
    for line in eachline(ignorestatus(`readelf -d $so_path`))
        m = match(r"\(NEEDED\)\s+Shared library: \[([^\]]+)\]", line)
        m !== nothing && push!(needed, m.captures[1])
    end
    return needed
end

# Parse `otool -L` output lines into a list of dylib basenames.
# First line is the library's own install name and is skipped.
function _parse_otool_output(lines::AbstractVector{<:AbstractString})
    needed = String[]
    length(lines) < 2 && return needed
    for line in lines[2:end]
        m = match(r"^\s+(\S+)\s+\(", line)
        m !== nothing && push!(needed, basename(m.captures[1]))
    end
    return needed
end

# Return the LC_LOAD_DYLIB install-name basenames listed in `so_path` (macOS, `otool -L`).
_otool_needed(so_path::AbstractString) =
    _parse_otool_output(collect(eachline(ignorestatus(`otool -L $so_path`))))

# Platform dispatch: DT_NEEDED on Linux, LC_LOAD_DYLIB on macOS, ImportTable on Windows.
_dynlib_needed(so_path::AbstractString) =
    Sys.isapple()   ? _otool_needed(so_path)   :
    Sys.iswindows() ? _objdump_needed(so_path)  :
    _readelf_needed(so_path)

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
        for soname in _dynlib_needed(path)
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
        _is_dynlib(name) || continue
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
    startup_benchmark(ext_path; mod_name=nothing, call_expr=nothing,
                      n=5, python="python3") -> NamedTuple

Measure first-import and (optionally) first-call latency for a built extension.
Each of the `n` trials runs in a **fresh subprocess** so import caching never
interferes. Typical numbers for a full-runtime bundled wheel: ~1–3 s import
(libjulia init dominates), < 1 ms first call (AOT-compiled, no JIT overhead).
With `slim=true` the import drops to ~0.3–0.8 s.

- `ext_path`: an importable file or directory — a `.so` built by `build_extension`,
  or a directory on `sys.path` containing the package.
- `mod_name`: module name to import; inferred from the filename if `nothing`
  (the first token before `.`).
- `call_expr`: Python expression to time as the **first call**, where the module
  is named `mod`, e.g. `"mod.add(1, 2)"`. Omit to measure import time only.
- `n`: number of independent subprocess trials (must be ≥ 1).

Returns a `NamedTuple` with fields:
  `n`, `import_ms_median`, `import_ms_min`, `import_ms_max`,
  `call_ms_median`, `call_ms_min`, `call_ms_max`
  (the `call_ms_*` fields are `nothing` when `call_expr` is not provided).

```julia-repl
julia> so = build_extension("mymod.jl"; outdir="build")
julia> r = startup_benchmark(so; call_expr="mod.add(1, 2)", n=5)
julia> @info "import \$(round(r.import_ms_median))ms  call \$(round(r.call_ms_median, digits=2))ms"
```
"""
function startup_benchmark(ext_path::AbstractString;
                           mod_name::Union{Nothing,AbstractString}=nothing,
                           call_expr::Union{Nothing,AbstractString}=nothing,
                           n::Int=5,
                           python::AbstractString="python3")
    n >= 1 || error("ParselTongue: startup_benchmark requires n ≥ 1")
    ext_path = abspath(ext_path)
    ext_dir  = isfile(ext_path) ? dirname(ext_path) : ext_path
    mname    = mod_name !== nothing ? String(mod_name) :
               String(split(basename(ext_path), '.')[1])

    call_block = call_expr !== nothing ? string(
        "t2 = time.perf_counter()\n",
        call_expr, "\n",
        "t3 = time.perf_counter()\n",
        "print(f',{(t3-t2)*1000:.6f}', end='')\n") : ""

    script = string(
        "import sys, time\n",
        "sys.path.insert(0, ", repr(ext_dir), ")\n",
        "t0 = time.perf_counter()\n",
        "import ", mname, " as mod\n",
        "t1 = time.perf_counter()\n",
        "print(f'{(t1-t0)*1000:.6f}', end='')\n",
        call_block,
        "print('')\n")

    import_times = Float64[]
    call_times   = Float64[]
    for _ in 1:n
        out = readchomp(`$python -c $script`)
        parts = split(strip(out), ',')
        push!(import_times, parse(Float64, parts[1]))
        call_expr !== nothing && length(parts) >= 2 &&
            push!(call_times, parse(Float64, parts[2]))
    end

    sort!(import_times); sort!(call_times)
    med(v) = isempty(v) ? nothing : v[div(length(v) + 1, 2)]

    return (
        n                = n,
        import_ms_median = med(import_times),
        import_ms_min    = isempty(import_times) ? nothing : import_times[1],
        import_ms_max    = isempty(import_times) ? nothing : import_times[end],
        call_ms_median   = med(call_times),
        call_ms_min      = isempty(call_times) ? nothing : call_times[1],
        call_ms_max      = isempty(call_times) ? nothing : call_times[end],
    )
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
