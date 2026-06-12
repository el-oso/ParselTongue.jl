# ── Export metadata + @pyfunc / @pymodule ─────────────────────────────
#
# `@pyfunc` annotates an ordinary Julia function definition. It (1) emits the
# function unchanged so it stays callable from Julia, and (2) records the
# signature in a registry on the build host. `build_extension` later reads the
# registry to generate the `@ccallable` wrappers and the C shim.

"""
    PtArg(name, jl_type, mutable=false)

One argument of an exported function: its name, the native Julia type the user
declared (e.g. `Int`, `String`), and whether it was marked `Mut{…}` (a writable,
in-place buffer).
"""
struct PtArg
    name::Symbol
    jl_type::Type
    mutable::Bool
end
PtArg(name::Symbol, jl_type::Type) = PtArg(name, jl_type, false)

"""
    PtExport(jl_func, export_name, args, ret, mod)

Metadata for one function exported to Python: the Julia function name, the
Python-visible name, its argument list, native return type, and defining module.
The generated C-ABI entry point is named `pt_<export_name>`.
"""
struct PtExport
    jl_func::Symbol
    export_name::String
    args::Vector{PtArg}
    ret::Type
    mod::Module
    submodule::String   # "" = top-level package namespace
end
PtExport(jl_func, export_name, args, ret, mod) =
    PtExport(jl_func, export_name, args, ret, mod, "")

cabi_symbol(e::PtExport) = string("pt_", e.export_name)

# A valid Python / C identifier (also the C-ABI symbol name).
_is_py_ident(s::AbstractString) = occursin(r"^[A-Za-z_][A-Za-z0-9_]*$", s)

# Default Python name for a Julia function: drop the trailing `!` mutation
# convention (Python has no such notion), then replace any remaining invalid
# characters with `_`. `scale!` -> `scale`, `Π` -> `_`.
function _default_py_name(s::AbstractString)
    n = replace(s, r"!+$" => "")
    n = replace(n, r"[^A-Za-z0-9_]" => "_")
    isempty(n) && (n = "_")
    occursin(r"^[0-9]", n) && (n = "_" * n)
    return n
end

# Build-host registry, populated when the user's file is `include`d.
const _EXPORTS = PtExport[]

"""
    clear_exports!()

Reset the export registry. Called at the start of each `build_extension`.
"""
clear_exports!() = (empty!(_EXPORTS); _MODULE_NAME[] = nothing; _CURRENT_SUBMODULE[] = ""; nothing)

# Distinct, ordered submodule names among `exports` (excluding the "" top level).
function submodule_names(exports::AbstractVector{PtExport})
    subs = String[]
    for e in exports
        s = e.submodule
        !isempty(s) && !(s in subs) && push!(subs, s)
    end
    subs
end

# Parse a function-definition expression into (name, [(argname, argtype_expr)...], rettype_expr).
function _parse_fundef(def)
    (def isa Expr && def.head in (:function, :(=))) ||
        error("@pyfunc expects a function definition, got: $(def)")
    sig = def.args[1]
    # Return type: `f(args)::Ret`
    ret_expr = :Any
    if sig isa Expr && sig.head == :(::)
        ret_expr = sig.args[2]
        sig = sig.args[1]
    end
    (sig isa Expr && sig.head == :call) ||
        error("@pyfunc: malformed signature in $(def)")
    fname = sig.args[1]
    fname isa Symbol || error("@pyfunc: function name must be a plain symbol, got $fname")
    args = Tuple{Symbol,Any,Bool}[]
    for a in sig.args[2:end]
        if a isa Expr && a.head == :(::) && length(a.args) == 2
            inner, mut = _peel_mut(a.args[2])
            a.args[2] = inner          # peel `Mut{T}` -> `T` in the emitted function
            push!(args, (a.args[1]::Symbol, inner, mut))
        elseif a isa Expr && a.head == :(::) && length(a.args) == 1
            error("@pyfunc: argument needs a name (got `::$(a.args[1])`); write `name::Type`.")
        else
            error("@pyfunc: every argument must be typed as `name::Type`, got `$a`.")
        end
    end
    return fname, args, ret_expr
end

# Detect a `Mut{Inner}` annotation (possibly module-qualified) and return
# `(inner_expr, true)`; otherwise `(type_expr, false)`.
function _peel_mut(t)
    if t isa Expr && t.head == :curly && length(t.args) == 2
        head = t.args[1]
        is_mut = head === :Mut ||
                 (head isa Expr && head.head == :. && head.args[2] === QuoteNode(:Mut))
        is_mut && return (t.args[2], true)
    end
    return (t, false)
end

"""
    @pyfunc function f(a::T, b::U)::R ... end
    @pyfunc f(a::T)::R = ...
    @pyfunc "py_name" function f(...) ... end

Mark a Julia function for export to Python. Emits the function normally and
records its signature for `build_extension`. All argument types and the return
type must be ParselTongue boundary types (scalars in v1).

An optional leading string sets the Python-visible name (defaults to the Julia
function name).
"""
macro pyfunc(arg1, arg2=nothing)
    if arg2 === nothing
        def = arg1
        pyname_expr = nothing
    else
        def = arg2
        pyname_expr = arg1
    end

    fname, args, ret_expr = _parse_fundef(def)
    export_name = if pyname_expr === nothing
        _default_py_name(string(fname))      # e.g. `scale!` -> `scale`
    elseif pyname_expr isa String
        _is_py_ident(pyname_expr) ? pyname_expr :
            error("@pyfunc: \"$pyname_expr\" is not a valid Python identifier.")
    else
        error("@pyfunc: python name must be a string literal, got $pyname_expr")
    end

    # Build the PtExport-construction expr; types are evaluated in the user module.
    arg_exprs = [:(ParselTongue.PtArg($(QuoteNode(n)), $(esc(t)), $mut)) for (n, t, mut) in args]

    quote
        $(esc(def))
        let e = ParselTongue.PtExport(
                $(QuoteNode(fname)),
                $export_name,
                ParselTongue.PtArg[$(arg_exprs...)],
                $(esc(ret_expr)),
                @__MODULE__,
                ParselTongue._CURRENT_SUBMODULE[],   # tag with the enclosing @pymodule submodule
            )
            ParselTongue._register_export!(e)
            e
        end
    end
end

# Register an export, validating its boundary types up front (clear errors at
# annotation time rather than deep in the build).
function _register_export!(e::PtExport)
    for a in e.args
        assert_boundary(a.jl_type)
    end
    # Returns are validated in the return direction (only need c_abi_type + to_c),
    # which also admits `Nothing` (void) and `Tuple{…}`.
    assert_ret_boundary(e.ret)
    # Replace any existing export with the same Python name (last definition wins).
    filter!(x -> x.export_name != e.export_name, _EXPORTS)
    push!(_EXPORTS, e)
    return e
end

"""
    @pymodule name begin ... end

Convenience wrapper: evaluate a block of `@pyfunc`-annotated definitions and
tag the collected exports with the Python module `name`. (v1: `name` is recorded
for `build_extension`; the block is spliced in place.)
"""
macro pymodule(name, block)
    pkg, sub = _parse_module_path(name)
    # The block must be spliced at top level (not inside a `try`/`let`) so the
    # user's `function`/`=` definitions create top-level globals — otherwise the
    # generated `@ccallable` wrappers see non-const `::Any` bindings, which
    # `--trim=safe` rejects as dynamic calls. The submodule context is reset at
    # the start of every build (`clear_exports!`), so no `finally` is needed.
    quote
        ParselTongue._set_module_name!($pkg)
        ParselTongue._CURRENT_SUBMODULE[] = $sub
        $(esc(block))
        ParselTongue._CURRENT_SUBMODULE[] = ""
        nothing
    end
end

# Parse a `@pymodule` name into (package, submodule). `mod` -> ("mod", ""),
# `pkg.sub` -> ("pkg", "sub"). Accepts a Symbol, a dotted expression, or a string.
function _parse_module_path(name)
    if name isa Symbol
        return string(name), ""
    elseif name isa String
        parts = split(name, '.')
        length(parts) == 1 && return String(parts[1]), ""
        length(parts) == 2 && return String(parts[1]), String(parts[2])
        error("@pymodule: name supports at most one dot (pkg.sub), got \"$name\".")
    elseif name isa Expr && name.head == :. && length(name.args) == 2 &&
           name.args[1] isa Symbol && name.args[2] isa QuoteNode
        return string(name.args[1]), string(name.args[2].value)
    end
    error("@pymodule: name must be `mod`, `pkg.sub`, or a string, got: $name")
end

const _MODULE_NAME = Ref{Union{Nothing,String}}(nothing)
const _CURRENT_SUBMODULE = Ref{String}("")

function _set_module_name!(s::AbstractString)
    if _MODULE_NAME[] !== nothing && _MODULE_NAME[] != s
        error("ParselTongue: conflicting @pymodule package names " *
              "\"$(_MODULE_NAME[])\" and \"$s\" — all blocks in one file must share the package.")
    end
    _MODULE_NAME[] = String(s)
    return nothing
end
