# ── Export metadata + @pyfunc / @pymodule ─────────────────────────────
#
# `@pyfunc` annotates an ordinary Julia function definition. It (1) emits the
# function unchanged so it stays callable from Julia, and (2) records the
# signature in a registry on the build host. `build_extension` later reads the
# registry to generate the `@ccallable` wrappers and the C shim.

"""
    PtArg(name, jl_type)

One argument of an exported function: its name and the native Julia type the
user declared (e.g. `Int`, `String`).
"""
struct PtArg
    name::Symbol
    jl_type::Type
end

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
end

cabi_symbol(e::PtExport) = string("pt_", e.export_name)

# Build-host registry, populated when the user's file is `include`d.
const _EXPORTS = PtExport[]

"""
    clear_exports!()

Reset the export registry. Called at the start of each `build_extension`.
"""
clear_exports!() = (empty!(_EXPORTS); nothing)

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
    args = Tuple{Symbol,Any}[]
    for a in sig.args[2:end]
        if a isa Expr && a.head == :(::) && length(a.args) == 2
            push!(args, (a.args[1]::Symbol, a.args[2]))
        elseif a isa Expr && a.head == :(::) && length(a.args) == 1
            error("@pyfunc: argument needs a name (got `::$(a.args[1])`); write `name::Type`.")
        else
            error("@pyfunc: every argument must be typed as `name::Type`, got `$a`.")
        end
    end
    return fname, args, ret_expr
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
    export_name = pyname_expr === nothing ? string(fname) :
                  (pyname_expr isa String ? pyname_expr :
                   error("@pyfunc: python name must be a string literal, got $pyname_expr"))

    # Build the PtExport-construction expr; types are evaluated in the user module.
    arg_exprs = [:(ParselTongue.PtArg($(QuoteNode(n)), $(esc(t)))) for (n, t) in args]

    quote
        $(esc(def))
        let e = ParselTongue.PtExport(
                $(QuoteNode(fname)),
                $export_name,
                ParselTongue.PtArg[$(arg_exprs...)],
                $(esc(ret_expr)),
                @__MODULE__,
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
    # v1 requires a boundary return type (Nothing/void returns come later).
    assert_boundary(e.ret)
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
    name isa Symbol || name isa String ||
        error("@pymodule: module name must be a symbol or string literal")
    quote
        ParselTongue._set_module_name!($(string(name)))
        $(esc(block))
    end
end

const _MODULE_NAME = Ref{Union{Nothing,String}}(nothing)
_set_module_name!(s::AbstractString) = (_MODULE_NAME[] = String(s); nothing)
