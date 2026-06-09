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
                keep_build=false, verbose=false) -> String

Build a self-contained, pip-installable wheel from the `@pyfunc`-annotated
functions in `user_path`. Returns the path to the `.whl`. The wheel bundles
libjulia, so the end user needs no Julia installation.
"""
function build_wheel(user_path::AbstractString;
                     version::AbstractString="0.1.0",
                     mod_name::Union{Nothing,AbstractString}=nothing,
                     outdir::AbstractString=dirname(abspath(user_path)),
                     python::AbstractString="python3",
                     trim::Symbol=:safe,
                     keep_build::Bool=false,
                     verbose::Bool=false)
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

    # 1. Build the extension as the internal submodule `_<mod>` with relative rpaths.
    ext_name = string("_", mod)
    build_extension(user_path;
                    mod_name=ext_name, outdir=pkgdir, trim, python,
                    runtime_rpaths=["\$ORIGIN/julia/lib", "\$ORIGIN/julia/lib/julia"],
                    strip_abs_rpath=true, keep_build, verbose)

    # 2. Vendor the Julia runtime, preserving the lib/ vs lib/julia/ layout so the
    #    bundled libs resolve each other through their existing RUNPATHs.
    libsrc = abspath(joinpath(Sys.BINDIR, "..", "lib"))
    _vendor_libs(libsrc, joinpath(pkgdir, "julia", "lib"))                  # libjulia.so*
    _vendor_libs(joinpath(libsrc, "julia"), joinpath(pkgdir, "julia", "lib", "julia"))

    # 3. __init__.py re-exports the compiled extension.
    write(joinpath(pkgdir, "__init__.py"), _init_py(mod, ext_name))

    # 4. dist-info metadata.
    distinfo = joinpath(stage, string(mod, "-", version, ".dist-info")); mkpath(distinfo)
    tag = _wheel_tag(python)
    write(joinpath(distinfo, "METADATA"), _metadata(mod, version))
    write(joinpath(distinfo, "WHEEL"), _wheel_meta(tag))

    # 5. Zip the tree into a .whl (Python helper computes RECORD hashes + zips).
    whl_name = string(mod, "-", version, "-", tag, ".whl")
    whl_path = joinpath(abspath(outdir), whl_name)
    _pack_wheel(python, stage, whl_path, string(mod, "-", version, ".dist-info"))
    verbose && @info "ParselTongue: built wheel $whl_path"
    return whl_path
end

function _init_py(mod, ext_name)
    """
    \"\"\"$mod — a Julia extension built with ParselTongue (juliac --trim).\"\"\"
    from .$ext_name import *  # noqa: F401,F403
    from . import $ext_name as _ext
    __all__ = [n for n in dir(_ext) if not n.startswith("_")]
    """
end

function _metadata(mod, version)
    """
    Metadata-Version: 2.1
    Name: $mod
    Version: $version
    Summary: $mod — Julia functions compiled to a native Python extension via ParselTongue
    Provides-Extra: numpy
    Requires-Dist: numpy; extra == "numpy"
    """
end

_wheel_meta(tag) = """
Wheel-Version: 1.0
Generator: ParselTongue (0.1.0)
Root-Is-Purelib: false
Tag: $tag
"""

# CPython wheel compatibility tag, e.g. "cp314-cp314-linux_x86_64".
function _wheel_tag(python::AbstractString)
    out = readchomp(`$python -c "import sysconfig,sys;v=sys.version_info;print(f'cp{v.major}{v.minor}-cp{v.major}{v.minor}-'+sysconfig.get_platform().replace('-','_').replace('.','_'))"`)
    return out
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
