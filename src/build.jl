# ── Build driver ──────────────────────────────────────────────────────
#
# build_extension: include the user's source (populating the export registry),
# generate the juliac entry + C shim, run juliac --trim to get `img.a`, then link
# the C shim + archive into an importable CPython extension module. Wheel
# packaging is layered on in Milestone 5.

# julia-config.jl exposes cflags()/ldflags()/ldlibs() but `using`s Libdl, so it
# can't be included at package-load time. Query it in a short subprocess instead
# (the same flags juliac.jl uses), evaluated lazily at build time.
function _juliaconfig(julia::AbstractString, flag::AbstractString)
    # Wrap the include in a module so julia-config.jl's `@main` is defined there
    # (not in Main) and does not auto-run when invoked via `-e`.
    script = "module JC; include(joinpath(Sys.BINDIR, Base.DATAROOTDIR, \"julia\", \"julia-config.jl\")); end; print(JC.$flag())"
    Base.shell_split(readchomp(`$julia --startup-file=no -e $script`))
end

struct BuildTools
    julia::String       # julia executable
    buildscript::String # juliac-buildscript.jl
    sysimage::String    # sys.so to build against
    cflags::Vector{String}
    ldflags::Vector{String}
    ldlibs::Vector{String}
    python::String      # python3 executable
    py_includes::Vector{String}
    ext_suffix::String  # e.g. ".cpython-314-x86_64-linux-gnu.so"
end

# Discover the toolchain, defensively (juliac is experimental — D9).
function _build_tools(; python::AbstractString="python3")
    julia = Base.julia_cmd().exec[1]
    bindir = Sys.BINDIR
    buildscript = joinpath(bindir, Base.DATAROOTDIR, "julia", "juliac", "juliac-buildscript.jl")
    isfile(buildscript) || error(
        "ParselTongue: juliac buildscript not found at $buildscript. " *
        "Need a Julia (≥1.12) that ships juliac.")
    sysimage = joinpath(bindir, "..", "lib", "julia", "sys." * Base.BinaryPlatforms.platform_dlext())
    isfile(sysimage) || error("ParselTongue: system image not found at $sysimage.")

    cflags  = _juliaconfig(julia, "cflags")
    ldflags = _juliaconfig(julia, "ldflags")
    ldlibs  = _juliaconfig(julia, "ldlibs")

    Sys.which(python) === nothing && error("ParselTongue: '$python' not found on PATH.")
    py_includes = _py_include_flags(python)
    ext_suffix = readchomp(`$python -c "import sysconfig;print(sysconfig.get_config_var('EXT_SUFFIX'))"`)

    BuildTools(julia, buildscript, sysimage, cflags, ldflags, ldlibs,
               string(python), py_includes, ext_suffix)
end

# python3 -m sysconfig has no simple "includes" flag; build -I list directly.
function _py_include_flags(python::AbstractString)
    paths = readlines(`$python -c "import sysconfig;print(sysconfig.get_path('include'));print(sysconfig.get_path('platinclude'))"`)
    flags = String[]
    for p in unique(filter(!isempty, paths))
        push!(flags, "-I" * p)
    end
    flags
end

"""
    build_extension(user_path; mod_name=nothing, outdir=dirname(user_path),
                    trim=:safe, python="python3", abi3=false, verbose=false) -> String

Compile the `@pyfunc`-annotated functions in `user_path` into an importable
CPython extension module and return the path to the produced `.so`.

`mod_name` defaults to the `@pymodule` name (if any) or the source file's base
name. `trim` is `:safe` (default), `:unsafe`, or `:unsafe_warn`.

When `abi3=true` the C shim is compiled against the stable ABI
(`Py_LIMITED_API=0x030B0000`, Python ≥ 3.11 floor) and the output uses the
`.abi3.so` extension suffix, so the resulting module loads on any CPython ≥ 3.11.
"""
function build_extension(user_path::AbstractString;
                         mod_name::Union{Nothing,AbstractString}=nothing,
                         outdir::AbstractString=dirname(abspath(user_path)),
                         trim::Symbol=:safe,
                         python::AbstractString="python3",
                         abi3::Bool=false,
                         runtime_rpaths::Vector{String}=String[],
                         strip_abs_rpath::Bool=false,
                         keep_build::Bool=false,
                         verbose::Bool=false,
                         # Internal: extra source files to `include` in the juliac entry
                         # (multi-module wheels aggregate several sources into one image).
                         _extra_includes::Vector{String}=String[],
                         # Internal: a registry snapshot NamedTuple (see _registry_snapshot)
                         # from build_wheel, to skip the second include of the user source.
                         _preloaded::Union{Nothing,NamedTuple}=nothing)
    user_path = abspath(user_path)
    isfile(user_path) || error("ParselTongue: source file not found: $user_path")
    trim in (:safe, :unsafe, :unsafe_warn) ||
        error("ParselTongue: trim must be :safe, :unsafe, or :unsafe_warn (got :$trim)")

    # 1. Populate the export registry by including the user source in a sandbox.
    #    When called from build_wheel, the caller already included the file and passes
    #    pre-populated exports/errors to avoid a redundant second include.
    spec = if _preloaded !== nothing
        _preloaded
    else
        clear_exports!()
        sandbox = Module(:ParselTongueUserSandbox)
        Core.eval(sandbox, :(using ParselTongue))
        Base.include(sandbox, user_path)
        _registry_snapshot()
    end
    exports              = spec.exports
    errors               = spec.errors
    handle_types         = spec.handle_types
    methods              = spec.methods
    news_list            = spec.news
    mutable_types        = spec.mutable_types
    properties           = spec.properties
    mutable_struct_types = spec.mutable_struct_types
    named_methods        = spec.named_methods
    subclass_types       = spec.subclass_types
    dict_types           = spec.dict_types
    isempty(exports) && error(
        "ParselTongue: no @pyfunc exports found in $user_path. " *
        "Annotate functions with @pyfunc.")
    # An instance __dict__ uses Py_TPFLAGS_MANAGED_DICT (CPython ≥ 3.12), which is not
    # part of the stable ABI — so `dict=true` is incompatible with an abi3 build.
    (abi3 && !isempty(dict_types)) && error(
        "ParselTongue: `dict=true` (instance __dict__, needs CPython ≥ 3.12) is " *
        "incompatible with abi3=true (stable-ABI floor 3.11). Types: " *
        "$(join(string.(dict_types), ", ")). Build without abi3, or drop dict=true.")

    mod = mod_name !== nothing ? String(mod_name) :
          _MODULE_NAME[] !== nothing ? _MODULE_NAME[] :
          _default_mod_name(user_path)
    _is_valid_modname(mod) || error("ParselTongue: invalid module name '$mod'.")

    mkpath(outdir)
    builddir = mktempdir(; prefix="parseltongue_", cleanup=!keep_build)
    tools = _build_tools(; python)
    # abi3 uses a version-neutral suffix; non-abi3 uses Python's EXT_SUFFIX.
    ext_suffix = abi3 ? _abi3_ext_suffix(tools.python) : tools.ext_suffix

    # 2. Generate the juliac entry file (loads user code + @ccallable wrappers).
    # Use invokelatest: @pyhandle definitions in the sandbox bump the world counter,
    # so c_abi_type dispatch inside the codegen must use the current latest world.
    entry_path = joinpath(builddir, "_pt_entry.jl")
    write(entry_path, Base.invokelatest(emit_entry, exports, user_path; errors, methods,
                                        news=news_list, properties, named_methods, mutable_struct_types,
                                        extra_includes=_extra_includes))

    # 3. Run juliac --trim to produce the trimmed object archive.
    img = joinpath(builddir, "img.a")
    _run_juliac(tools, entry_path, img, trim, verbose)

    # 4. Generate the C PyInit shim.
    cpath = joinpath(builddir, string("_", mod, "module.c"))
    write(cpath, Base.invokelatest(emit_cshim, mod, exports, errors, handle_types, methods, news_list;
                                   mutable_types, mutable_struct_types, properties, named_methods,
                                   subclass_types, dict_types, abi3))

    # 5. Link the shim + archive into the extension module.
    so_path = joinpath(outdir, string(mod, ext_suffix))
    _link_extension(tools, cpath, img, so_path, runtime_rpaths, strip_abs_rpath, verbose)

    verbose && @info "ParselTongue: built $so_path ($(length(exports)) function(s))"
    return so_path
end

_default_mod_name(p) = first(split(basename(p), '.'))
_is_valid_modname(s) = occursin(r"^[A-Za-z_][A-Za-z0-9_]*$", s)

# Query Python's importlib for the abi3 extension suffix.
# On POSIX: '.abi3.so'; on Windows there is no 'abi3' in EXTENSION_SUFFIXES, fall back to '.pyd'.
function _abi3_ext_suffix(python::AbstractString)
    script = "import importlib.machinery as m, sys; " *
             "s = next((x for x in m.EXTENSION_SUFFIXES if 'abi3' in x), None); " *
             "print(s or ('.pyd' if sys.platform == 'win32' else '.abi3.so'))"
    return readchomp(`$python -c $script`)
end

function _run_juliac(t::BuildTools, entry::AbstractString, img::AbstractString,
                     trim::Symbol, verbose::Bool)
    trimflag = trim === :safe ? "--trim=safe" :
               trim === :unsafe ? "--trim=unsafe" : "--trim=unsafe-warn"
    project = Base.active_project()
    cmd = `$(t.julia) -t 1 -J $(t.sysimage) --startup-file=no --history-file=no
           --project=$project
           --output-o $img --output-incremental=no --strip-ir --strip-metadata
           --experimental $trimflag
           $(t.buildscript) $entry --output-lib true $(img * ".abi.json")`
    cmd = addenv(cmd, "OPENBLAS_NUM_THREADS" => "1", "JULIA_NUM_THREADS" => "1")
    verbose && @info "ParselTongue: running juliac" cmd
    if !success(pipeline(cmd; stdout, stderr))
        error("ParselTongue: juliac --trim failed. Re-run with verbose=true; a " *
              "`--trim=safe` error usually means dynamic dispatch in an exported path.")
    end
    isfile(img) || error("ParselTongue: juliac did not produce $img.")
    return img
end

function _link_extension(t::BuildTools, cpath::AbstractString, img::AbstractString,
                         so_path::AbstractString, runtime_rpaths::Vector{String},
                         strip_abs_rpath::Bool, verbose::Bool)
    cc = _find_cc()
    pyinc = t.py_includes
    rpath_flags = [string("-Wl,-rpath,", rp) for rp in runtime_rpaths]
    # Extension modules must NOT link libpython on Unix (the interpreter provides
    # the symbols). On Windows, Python symbols must be linked explicitly.
    if Sys.iswindows()
        # Windows / MinGW-w64. No rpaths — DLL search handled by __init__.py
        # add_dll_directory. Link Python DLL explicitly. MSVC not yet supported.
        pylibs = _py_lib_flags(t.python)
        cmd = `$cc -shared $cpath $pyinc
               -Wl,--whole-archive $img -Wl,--no-whole-archive
               $(t.cflags) $(t.ldflags) $(t.ldlibs) -ljulia-internal
               $pylibs
               -o $so_path`
    elseif Sys.isapple()
        # macOS: julia-config may emit `-rpath /abs` (no -Wl,) or `-Wl,-rpath,/abs`.
        _is_rpath(f) = startswith(f, "-Wl,-rpath") || startswith(f, "-rpath")
        ldflags = strip_abs_rpath ? filter(!_is_rpath, t.ldflags) : t.ldflags
        ldlibs  = strip_abs_rpath ? filter(!_is_rpath, t.ldlibs)  : t.ldlibs
        # -force_load is the macOS equivalent of --whole-archive (archive-specific).
        # -undefined dynamic_lookup: Python symbols are provided by the interpreter.
        cmd = `$cc -dynamiclib -undefined dynamic_lookup $cpath $pyinc
               -Wl,-force_load,$img
               $(t.cflags) $ldflags $ldlibs -ljulia-internal
               $rpath_flags
               -o $so_path`
    else
        # Linux: drop absolute rpaths julia-config bakes in; add our own $ORIGIN-relative
        # ones so the bundled libs resolve each other via their existing RUNPATHs.
        ldflags = strip_abs_rpath ? filter(f -> !startswith(f, "-Wl,-rpath"), t.ldflags) : t.ldflags
        ldlibs  = strip_abs_rpath ? filter(f -> !startswith(f, "-Wl,-rpath"), t.ldlibs)  : t.ldlibs
        cmd = `$cc -shared -fPIC $cpath $pyinc
               -Wl,--whole-archive $img -Wl,--no-whole-archive
               $(t.cflags) $ldflags $ldlibs -ljulia-internal
               $rpath_flags
               -o $so_path`
    end
    verbose && @info "ParselTongue: linking" cmd
    if !success(pipeline(cmd; stdout, stderr))
        error("ParselTongue: linking the extension module failed.")
    end
    isfile(so_path) || error("ParselTongue: link did not produce $so_path.")
    return so_path
end

function _find_cc()
    cc = get(ENV, "JULIA_CC", get(ENV, "CC", nothing))
    cc !== nothing && return Cmd(Base.shell_split(cc))
    if Sys.iswindows()
        # Prefer MinGW-w64 GCC; MSVC (cl.exe) is not yet supported.
        for c in ("gcc", "x86_64-w64-mingw32-gcc", "clang")
            Sys.which(c) !== nothing && return `$c`
        end
        error("ParselTongue: no C compiler found on Windows. " *
              "Install MinGW-w64 (via MSYS2 or Julia's bundled toolchain) " *
              "and ensure gcc is on PATH, or set JULIA_CC.")
    end
    for c in ("cc", "gcc", "clang")
        Sys.which(c) !== nothing && return `$c`
    end
    error("ParselTongue: no C compiler found (looked for cc, gcc, clang).")
end

# On Windows, extension modules must link the Python DLL explicitly at link time
# (there is no -undefined dynamic_lookup equivalent). On Unix the interpreter
# provides all Python-API symbols at load time via the process's symbol table.
# Returns ["-L<libs_dir>", "-l<pythonXY>"] on Windows; String[] on Unix.
function _py_lib_flags(python::AbstractString)
    Sys.iswindows() || return String[]
    script = "import sys; v=f'{sys.version_info.major}{sys.version_info.minor}'; " *
             "print(sys.prefix+'/libs'); print('python'+v)"
    parts = readlines(`$python -c $script`)
    length(parts) >= 2 || return String[]
    ["-L" * strip(parts[1]), "-l" * strip(parts[2])]
end
