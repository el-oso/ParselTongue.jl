# ── Export metadata + @pyfunc / @pymodule ─────────────────────────────
#
# `@pyfunc` annotates an ordinary Julia function definition. It (1) emits the
# function unchanged so it stays callable from Julia, and (2) records the
# signature in a registry on the build host. `build_extension` later reads the
# registry to generate the `@ccallable` wrappers and the C shim.

"""
    PtArg(name, jl_type, mutable=false, default=nothing)

One argument of an exported function: its name, the native Julia type the user
declared (e.g. `Int`, `String`), whether it was marked `Mut{…}` (a writable,
in-place buffer), and the default value (or `nothing` if the argument is required).
"""
struct PtArg
    name::Symbol
    jl_type::Type
    mutable::Bool
    default::Union{Nothing,Any}   # nothing = required; any value = optional
    is_keyword::Bool              # true = declared after `;` in the Julia signature
end
PtArg(name::Symbol, jl_type::Type) = PtArg(name, jl_type, false, nothing, false)
PtArg(name::Symbol, jl_type::Type, mutable::Bool) = PtArg(name, jl_type, mutable, nothing, false)
PtArg(name::Symbol, jl_type::Type, mutable::Bool, default) = PtArg(name, jl_type, mutable, default, false)

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

"""
    PtError(jl_type, py_name, parent)

One custom Python exception registered via `@pyerror`. `jl_type` is the Julia
exception type, `py_name` is its Python-visible name, and `parent` is the C
expression for its Python parent class (e.g. `"PyExc_ValueError"`).
"""
struct PtError
    jl_type::Type
    py_name::String
    parent::String    # C expression, e.g. "PyExc_Exception"
end

# Build-host registry for custom exception types.
const _ERRORS = PtError[]

# ── @pymethod metadata ─────────────────────────────────────────────────

# Supported dunder slots: symbol → (C slot constant, required Julia return type).
# ret_type=nothing means any boundary return type is accepted (validated via c_abi_type).
const _PYMETHOD_SLOTS = Dict{Symbol,NamedTuple}(
    :__repr__     => (slot="Py_tp_repr",      ret_type=String),
    :__str__      => (slot="Py_tp_str",       ret_type=String),
    :__len__      => (slot="Py_sq_length",    ret_type=Int64),
    :__hash__     => (slot="Py_tp_hash",      ret_type=Int64),
    :__bool__     => (slot="Py_nb_bool",      ret_type=Bool),
    :__getitem__  => (slot="Py_sq_item",      ret_type=nothing),
    # Write-back mutation: Julia fn returns new T, ccallable stores it back.
    :__setitem__  => (slot="Py_sq_ass_item",  ret_type=:writeback),
    # Extra args from parsed tuple (parse_args sentinel).
    :__call__     => (slot="Py_tp_call",      ret_type=nothing),
    # Single value unboxed from PyObject*.
    :__contains__ => (slot="Py_sq_contains",  ret_type=Bool),
    # Self-return iterator: Py_INCREF(self); return self — no Julia call.
    :__iter__     => (slot="Py_tp_iter",      ret_type=:same_handle_type),
    # Context managers: registered via Py_tp_methods (PyMethodDef), not type slots.
    :__enter__    => (slot="Py_tp_methods",   ret_type=:same_handle_type),
    :__exit__     => (slot="Py_tp_methods",   ret_type=Bool),
    # Stateful iteration: ret = Union{V,Nothing} (None → StopIteration). For
    # @pymutable types the body advances state in-place; for @pyhandle the new
    # state is written back via unsafe_store! (handled like __setitem__ write-back).
    :__next__     => (slot="Py_tp_iternext",  ret_type=nothing),
    :__eq__       => (slot="Py_tp_richcompare", ret_type=Bool),
    :__ne__       => (slot="Py_tp_richcompare", ret_type=Bool),
    :__lt__       => (slot="Py_tp_richcompare", ret_type=Bool),
    :__le__       => (slot="Py_tp_richcompare", ret_type=Bool),
    :__gt__       => (slot="Py_tp_richcompare", ret_type=Bool),
    :__ge__       => (slot="Py_tp_richcompare", ret_type=Bool),
    # Numeric protocol — binary ops take a same-handle `other`; unary ops take
    # only self. Return is any boundary type (usually the handle type itself).
    :__add__      => (slot="Py_nb_add",             ret_type=nothing),
    :__sub__      => (slot="Py_nb_subtract",        ret_type=nothing),
    :__mul__      => (slot="Py_nb_multiply",        ret_type=nothing),
    :__truediv__  => (slot="Py_nb_true_divide",     ret_type=nothing),
    :__floordiv__ => (slot="Py_nb_floor_divide",    ret_type=nothing),
    :__mod__      => (slot="Py_nb_remainder",       ret_type=nothing),
    :__pow__      => (slot="Py_nb_power",           ret_type=nothing),
    :__matmul__   => (slot="Py_nb_matrix_multiply", ret_type=nothing),
    :__neg__      => (slot="Py_nb_negative",        ret_type=nothing),
    :__pos__      => (slot="Py_nb_positive",        ret_type=nothing),
    :__abs__      => (slot="Py_nb_absolute",        ret_type=nothing),
    :__invert__   => (slot="Py_nb_invert",          ret_type=nothing),
    # Reflected binary ops — map to the SAME Py_nb_* slot as the forward op
    # (the C number protocol uses one slot per operand order). `self` is the
    # handle operand; `other` is the scalar left operand.
    :__radd__      => (slot="Py_nb_add",             ret_type=nothing),
    :__rsub__      => (slot="Py_nb_subtract",        ret_type=nothing),
    :__rmul__      => (slot="Py_nb_multiply",        ret_type=nothing),
    :__rtruediv__  => (slot="Py_nb_true_divide",     ret_type=nothing),
    :__rfloordiv__ => (slot="Py_nb_floor_divide",    ret_type=nothing),
    :__rmod__      => (slot="Py_nb_remainder",       ret_type=nothing),
    :__rpow__      => (slot="Py_nb_power",           ret_type=nothing),
    :__rmatmul__   => (slot="Py_nb_matrix_multiply", ret_type=nothing),
)

# Numeric dunders: binary (self, other), reflected binary (scalar OP self), and
# unary (self only). `__pow__`/`__rpow__` are the ternaryfunc slot (modulo ignored).
# `other` of a binary/reflected op may be the same handle type OR a scalar boundary
# type, enabling mixed-type operators (vec*2.0, 2.0*vec).
const _NUMERIC_BINARY_DUNDERS =
    (:__add__, :__sub__, :__mul__, :__truediv__, :__floordiv__,
     :__mod__, :__pow__, :__matmul__)
const _NUMERIC_REFLECTED_DUNDERS =
    (:__radd__, :__rsub__, :__rmul__, :__rtruediv__, :__rfloordiv__,
     :__rmod__, :__rpow__, :__rmatmul__)
const _NUMERIC_UNARY_DUNDERS = (:__neg__, :__pos__, :__abs__, :__invert__)
is_numeric_binary(d::Symbol)    = d in _NUMERIC_BINARY_DUNDERS
is_numeric_reflected(d::Symbol) = d in _NUMERIC_REFLECTED_DUNDERS
is_numeric_unary(d::Symbol)     = d in _NUMERIC_UNARY_DUNDERS

# Extra positional argument types (after self) for dunders that take more than self.
# :same_handle    — second arg must be the same @pyhandle type as self (comparisons).
# :numeric_other  — single extra arg; the same handle type OR a scalar (numeric ops, mixed-type).
# :setitem_val    — two extra args: idx::Int64 + val::<boundary>. Return must equal T (writeback).
# :parse_args     — any number of extra boundary args (for __call__).
# :pyobj_val      — single extra boundary arg unboxed from PyObject* (for __contains__).
const _PYMETHOD_EXTRA_ARGS = Dict{Symbol,Any}(
    :__getitem__  => Type[Int64],
    :__setitem__  => :setitem_val,
    :__call__     => :parse_args,
    :__contains__ => :pyobj_val,
    :__eq__       => :same_handle,
    :__ne__       => :same_handle,
    :__lt__       => :same_handle,
    :__le__       => :same_handle,
    :__gt__       => :same_handle,
    :__ge__       => :same_handle,
    # Binary numeric ops: second operand must be the same handle type.
    :__add__      => :numeric_other,
    :__sub__      => :numeric_other,
    :__mul__      => :numeric_other,
    :__truediv__  => :numeric_other,
    :__floordiv__ => :numeric_other,
    :__mod__      => :numeric_other,
    :__pow__      => :numeric_other,
    :__matmul__   => :numeric_other,
    # Reflected ops: `other` is the scalar left operand.
    :__radd__      => :numeric_other,
    :__rsub__      => :numeric_other,
    :__rmul__      => :numeric_other,
    :__rtruediv__  => :numeric_other,
    :__rfloordiv__ => :numeric_other,
    :__rmod__      => :numeric_other,
    :__rpow__      => :numeric_other,
    :__rmatmul__   => :numeric_other,
)

"""
    PtMethod(handle_type, dunder, jl_func, self_arg, ret[, extra_args])

Metadata for one Python dunder method registered via [`@pymethod`](@ref).
`handle_type` is the `@pyhandle` type; `dunder` the Python slot symbol
(e.g. `:__repr__`); `jl_func` the user's Julia function name; `self_arg`
the self `PtArg`; `ret` the Julia return type; `extra_args` the extra
positional args beyond self (empty for most dunders).
"""
struct PtMethod
    handle_type::Type
    dunder::Symbol
    jl_func::Symbol
    self_arg::PtArg
    ret::Type
    extra_args::Vector{PtArg}
end
PtMethod(ht, d, jf, sa, r) = PtMethod(ht, d, jf, sa, r, PtArg[])

# C-ABI symbol for the @ccallable wrapper: pt_meth_<TypeName>_<clean>.
# <clean> strips the leading/trailing __ from the dunder name.
cabi_symbol(m::PtMethod) = string("pt_meth_", m.handle_type.name.name, "_",
    replace(replace(string(m.dunder), r"^__" => ""), r"__$" => ""))

# Build-host registry for @pymethod registrations.
const _METHODS = PtMethod[]

"""
    PtNew(handle_type, jl_func, args)

Constructor registered via `@pymethod __new__`. When Python calls `T(args...)`,
the C `tp_new` slot invokes `jl_func(args...)` and wraps the result as a `T` object.
"""
struct PtNew
    handle_type::Type
    jl_func::Symbol
    args::Vector{PtArg}
end

cabi_symbol(n::PtNew) = string("pt_new_", n.handle_type.name.name)

const _NEWS = PtNew[]

"""
    PtProperty(handle_type, prop_name, getter_fn, setter_fn, val_type)

A Python property registered via `@pyproperty`. `getter_fn` is the Julia
function symbol for the getter; `setter_fn` is `nothing` for read-only properties.
`val_type` is the Julia type of the property value (must be a boundary type).
"""
struct PtProperty
    handle_type::Type
    prop_name::String
    getter_fn::Symbol
    setter_fn::Union{Symbol,Nothing}
    val_type::Type
end

"""
    PtNamedMethod(handle_type, py_name, jl_func, self_arg, extra_args, ret)

A bound, named instance method registered via `@pymethod name f(self::T, …) = …`
(name is a plain identifier, not a dunder). Exposed as `obj.name(args)` via the
type's `PyMethodDef` table (`Py_tp_methods`). Like a `@pyfunc` whose first argument
is the handle, but invoked as a method on the Python object.
"""
struct PtNamedMethod
    handle_type::Type
    py_name::String
    jl_func::Symbol
    self_arg::PtArg
    extra_args::Vector{PtArg}
    ret::Type
end

cabi_symbol(m::PtNamedMethod) = string("pt_namedmeth_", m.handle_type.name.name, "_", m.py_name)

# Build-host registries for mutable handle types, properties, and named methods.
const _MUTABLE_HANDLE_TYPES = Type[]
const _PROPERTIES = PtProperty[]
const _NAMED_METHODS = PtNamedMethod[]

# Opt-in subclassing flags (mirror PyO3 #[pyclass(subclass)] / #[pyclass(dict)]).
# _SUBCLASS_TYPES: Py_TPFLAGS_BASETYPE + subclass-aware tp_new (abi3-safe).
# _DICT_TYPES: instance __dict__ via managed dict (CPython ≥ 3.12; incompatible with abi3).
const _SUBCLASS_TYPES = Type[]
const _DICT_TYPES = Type[]

# Build-host registry for @pymutable types: non-isbits `mutable struct`s backed by
# a per-type Julia GC registry (Dict{Int64,T}). Distinct from _MUTABLE_HANDLE_TYPES,
# which marks isbits @pyhandle types that gained in-place setattr via O6. A @pymutable
# type also appears in _HANDLE_TYPES (it still needs a PyTypeObject), but its dealloc
# and field access route through Julia (registry lookup) rather than raw C memory.
const _MUTABLE_STRUCT_TYPES = Type[]

function _register_new!(n::PtNew)
    T = n.handle_type
    ishandle(c_abi_type(T)) ||
        error("@pymethod __new__: type `$T` is not registered with @pyhandle.")
    T in _HANDLE_TYPES || push!(_HANDLE_TYPES, T)
    filter!(x -> x.handle_type !== T, _NEWS)
    push!(_NEWS, n)
    return n
end

function _register_method!(m::PtMethod)
    T = m.handle_type
    # Use c_abi_type dispatch (registered by @pyhandle, persists across clear_exports!)
    # to validate that T is a handle type. Also ensure it's tracked in _HANDLE_TYPES
    # for PyTypeObject generation (re-adds if clear_exports! removed it).
    ishandle(c_abi_type(T)) ||
        error("@pymethod: type `$T` is not registered with @pyhandle.")
    T in _HANDLE_TYPES || push!(_HANDLE_TYPES, T)
    spec = _PYMETHOD_SLOTS[m.dunder]

    # Validate return type.
    if spec.ret_type === :writeback || spec.ret_type === :same_handle_type
        # Write-back (__setitem__) and self-return (__iter__, __enter__) require ret == T.
        m.ret === T ||
            error("@pymethod $(m.dunder): return type must equal the handle type `$T`, got `$(m.ret)`.")
    elseif spec.ret_type === nothing
        # Polymorphic return (__getitem__, __call__): any non-Nothing boundary type.
        m.ret === Nothing &&
            error("@pymethod $(m.dunder): return type must not be Nothing.")
        try
            c_abi_type(m.ret)
        catch e
            error("@pymethod $(m.dunder): return type `$(m.ret)` is not a boundary type: $e")
        end
    else
        # Fixed return type (__repr__ → String, __len__ → Int64, etc.).
        m.ret === spec.ret_type ||
            error("@pymethod $(m.dunder): return type must be `$(spec.ret_type)`, got `$(m.ret)`.")
    end

    # __next__ must return Union{V,Nothing} (None → StopIteration).
    if m.dunder === :__next__
        isopt(c_abi_type(m.ret)) ||
            error("@pymethod __next__: return type must be `Union{V, Nothing}` " *
                  "(return `nothing` to stop iteration), got `$(m.ret)`.")
    end

    # Validate extra args based on dunder.
    if m.dunder === :__setitem__
        length(m.extra_args) == 2 ||
            error("@pymethod __setitem__: need exactly 2 extra args (idx::Int64, val::<T>), got $(length(m.extra_args)).")
        m.extra_args[1].jl_type === Int64 ||
            error("@pymethod __setitem__: first extra arg must be ::Int64 (index), got $(m.extra_args[1].jl_type).")
        try; c_abi_type(m.extra_args[2].jl_type); catch e
            error("@pymethod __setitem__: value type `$(m.extra_args[2].jl_type)` is not a boundary type: $e")
        end
    elseif m.dunder === :__contains__
        length(m.extra_args) == 1 ||
            error("@pymethod __contains__: need exactly 1 extra arg (the value), got $(length(m.extra_args)).")
        try; c_abi_type(m.extra_args[1].jl_type); catch e
            error("@pymethod __contains__: value type `$(m.extra_args[1].jl_type)` is not a boundary type: $e")
        end
    elseif m.dunder === :__call__
        isempty(m.extra_args) &&
            error("@pymethod __call__: need at least 1 extra arg (in addition to self).")
        for a in m.extra_args
            try; c_abi_type(a.jl_type); catch e
                error("@pymethod __call__: arg `$(a.name)::$(a.jl_type)` is not a boundary type: $e")
            end
        end
    elseif is_numeric_binary(m.dunder) || is_numeric_reflected(m.dunder)
        length(m.extra_args) == 1 ||
            error("@pymethod $(m.dunder): need exactly 1 operand arg (in addition to self), got $(length(m.extra_args)).")
        ot = m.extra_args[1].jl_type
        try; c_abi_type(ot); catch e
            error("@pymethod $(m.dunder): operand type `$ot` is not a boundary type: $e")
        end
        # Reflected ops are dispatched when `self` is the right operand and the left
        # operand is a non-handle scalar, so `other` cannot be the handle type.
        is_numeric_reflected(m.dunder) && ot === T &&
            error("@pymethod $(m.dunder): reflected operator's operand must be a scalar, " *
                  "not the handle type `$T` (handle×handle is the forward op).")
    end

    filter!(x -> !(x.handle_type === T && x.dunder === m.dunder), _METHODS)
    push!(_METHODS, m)
    return m
end

function _register_named_method!(m::PtNamedMethod)
    T = m.handle_type
    ishandle(c_abi_type(T)) ||
        error("@pymethod $(m.py_name): type `$T` is not registered with @pyhandle/@pymutable.")
    T in _HANDLE_TYPES || push!(_HANDLE_TYPES, T)
    m.ret === Nothing || try
        c_abi_type(m.ret)
    catch e
        error("@pymethod $(m.py_name): return type `$(m.ret)` is not a boundary type: $e")
    end
    for a in m.extra_args
        try; c_abi_type(a.jl_type); catch e
            error("@pymethod $(m.py_name): arg `$(a.name)::$(a.jl_type)` is not a boundary type: $e")
        end
    end
    filter!(x -> !(x.handle_type === T && x.py_name == m.py_name), _NAMED_METHODS)
    push!(_NAMED_METHODS, m)
    return m
end

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
clear_exports!() = (empty!(_EXPORTS); empty!(_ERRORS); empty!(_HANDLE_TYPES); empty!(_METHODS); empty!(_NEWS); empty!(_MUTABLE_HANDLE_TYPES); empty!(_PROPERTIES); empty!(_MUTABLE_STRUCT_TYPES); empty!(_NAMED_METHODS); empty!(_SUBCLASS_TYPES); empty!(_DICT_TYPES); _MODULE_NAME[] = nothing; _CURRENT_SUBMODULE[] = ""; nothing)

"""
    _registry_snapshot() -> NamedTuple

Copy all build-host registries into a NamedTuple — the `_preloaded` payload passed
from `build_wheel`/`build_multi_wheel` to `build_extension` to skip a second include.
Named fields let the pipeline grow without reshuffling a positional tuple.
"""
_registry_snapshot() = (
    exports              = copy(_EXPORTS),
    errors               = copy(_ERRORS),
    handle_types         = copy(_HANDLE_TYPES),
    methods              = copy(_METHODS),
    news                 = copy(_NEWS),
    mutable_types        = copy(_MUTABLE_HANDLE_TYPES),
    properties           = copy(_PROPERTIES),
    mutable_struct_types = copy(_MUTABLE_STRUCT_TYPES),
    named_methods        = copy(_NAMED_METHODS),
    subclass_types       = copy(_SUBCLASS_TYPES),
    dict_types           = copy(_DICT_TYPES),
)

# Distinct, ordered submodule names among `exports` (excluding the "" top level).
function submodule_names(exports::AbstractVector{PtExport})
    subs = String[]
    for e in exports
        s = e.submodule
        !isempty(s) && !(s in subs) && push!(subs, s)
    end
    subs
end

# Map a Python exception class name symbol to its C global expression.
const _PY_EXC_CNAMES = Dict{Symbol,String}(
    :Exception          => "PyExc_Exception",
    :ValueError         => "PyExc_ValueError",
    :TypeError          => "PyExc_TypeError",
    :RuntimeError       => "PyExc_RuntimeError",
    :ArithmeticError    => "PyExc_ArithmeticError",
    :LookupError        => "PyExc_LookupError",
    :IndexError         => "PyExc_IndexError",
    :KeyError           => "PyExc_KeyError",
    :AttributeError     => "PyExc_AttributeError",
    :ImportError        => "PyExc_ImportError",
    :MemoryError        => "PyExc_MemoryError",
    :NotImplementedError=> "PyExc_NotImplementedError",
    :OSError            => "PyExc_OSError",
    :OverflowError      => "PyExc_OverflowError",
    :StopIteration      => "PyExc_StopIteration",
)

function _py_exc_cname(parent_sym::Symbol)
    haskey(_PY_EXC_CNAMES, parent_sym) && return _PY_EXC_CNAMES[parent_sym]
    error("@pyerror: unknown Python exception parent `$parent_sym`. " *
          "Supported: $(join(sort!(collect(string.(keys(_PY_EXC_CNAMES)))), ", ")).")
end

"""
    @pyerror ExcType
    @pyerror ExcType <: PythonParent

Register a Julia exception type as a named Python exception. The generated Python
module will have an `ExcType` attribute that Python callers can `except`. Any
`@pyfunc` that `throw`s a value of this type will raise that specific Python
exception rather than a generic `RuntimeError`.

`PythonParent` is a standard Python exception class name (e.g. `ValueError`,
`ArithmeticError`); defaults to `Exception`.
"""
macro pyerror(expr)
    # Accepted forms:
    #   @pyerror MyError          → expr = :MyError
    #   @pyerror MyError <: Foo   → expr = :(MyError <: Foo)
    if expr isa Expr && expr.head === :(<:) && length(expr.args) == 2
        err_sym    = expr.args[1]::Symbol
        parent_sym = expr.args[2]::Symbol
        parent_c   = _py_exc_cname(parent_sym)
    elseif expr isa Symbol
        err_sym  = expr
        parent_c = "PyExc_Exception"
    else
        error("@pyerror: expected `ExcType` or `ExcType <: PythonParent`, got: $expr")
    end
    py_name = string(err_sym)
    quote
        let _et = Core.eval(@__MODULE__, $(QuoteNode(err_sym)))
            push!(ParselTongue._ERRORS, ParselTongue.PtError(_et, $py_name, $parent_c))
        end
    end
end

# Parse one positional or keyword arg node into (name, type_expr, mutable, default_expr).
# `a` is one element from the sig.args list (or from a :parameters block).
function _parse_one_arg(a)
    if a isa Expr && a.head == :kw
        # `b::T = val` — typed arg with default value
        typed, default_expr = a.args
        if typed isa Expr && typed.head == :(::) && length(typed.args) == 2
            inner, mut = _peel_mut(typed.args[2])
            typed.args[2] = inner
            return (typed.args[1]::Symbol, inner, mut, default_expr)
        end
        error("@pyfunc: defaulted argument must be typed: `name::Type = default`, got `$a`.")
    elseif a isa Expr && a.head == :(::) && length(a.args) == 2
        inner, mut = _peel_mut(a.args[2])
        a.args[2] = inner
        return (a.args[1]::Symbol, inner, mut, nothing)
    elseif a isa Expr && a.head == :(::) && length(a.args) == 1
        error("@pyfunc: argument needs a name (got `::$(a.args[1])`); write `name::Type`.")
    else
        error("@pyfunc: every argument must be typed as `name::Type`, got `$a`.")
    end
end

# Parse a function-definition expression into (name, [(name,type,mut,default)…], rettype_expr).
# Supports positional args, positional args with defaults (`b::T=val`), and
# keyword args (`; b::T=val` or `; b::T`). Julia's AST puts the :parameters block
# (keyword args) first in sig.args, so we collect positional and keyword args
# separately and concatenate them: positional first, keywords after.
function _parse_fundef(def)
    (def isa Expr && def.head in (:function, :(=))) ||
        error("@pyfunc expects a function definition, got: $(def)")
    sig = def.args[1]
    ret_expr = :Any
    if sig isa Expr && sig.head == :(::)
        ret_expr = sig.args[2]
        sig = sig.args[1]
    end
    (sig isa Expr && sig.head == :call) ||
        error("@pyfunc: malformed signature in $(def)")
    fname = sig.args[1]
    fname isa Symbol || error("@pyfunc: function name must be a plain symbol, got $fname")

    pos_args = Tuple{Symbol,Any,Bool,Any,Bool}[]   # positional (incl. with defaults)
    kw_args  = Tuple{Symbol,Any,Bool,Any,Bool}[]   # from ; block (is_keyword=true)
    for a in sig.args[2:end]
        if a isa Expr && a.head == :parameters
            for ka in a.args
                (n, t, mut, d) = _parse_one_arg(ka)
                push!(kw_args, (n, t, mut, d, true))
            end
        else
            (n, t, mut, d) = _parse_one_arg(a)
            push!(pos_args, (n, t, mut, d, false))
        end
    end
    args = vcat(pos_args, kw_args)

    # Required args must precede optional ones (Python's C-API constraint).
    saw_optional = false
    for (_, _, _, d, _) in args
        if d === nothing
            saw_optional && error(
                "@pyfunc: required argument follows an optional one — " *
                "put all arguments with defaults after those without.")
        else
            saw_optional = true
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

    # Build the PtExport-construction expr; types + defaults are evaluated in the user module.
    arg_exprs = [:(ParselTongue.PtArg($(QuoteNode(n)), $(esc(t)), $mut, $(esc(d)), $kw))
                 for (n, t, mut, d, kw) in args]

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
    isvarargs(e.ret) && error("@pyfunc: `PtVarArgs` cannot be used as a return type.")
    assert_ret_boundary(e.ret)
    # Validate PtVarArgs constraints.
    va_indices = findall(a -> isvarargs(a.jl_type), e.args)
    if length(va_indices) > 1
        error("@pyfunc: at most one PtVarArgs argument is allowed.")
    end
    if length(va_indices) == 1
        vi = va_indices[1]
        e.args[vi].mutable &&
            error("@pyfunc: PtVarArgs argument `$(e.args[vi].name)` cannot be Mut.")
        e.args[vi].default !== nothing &&
            error("@pyfunc: PtVarArgs argument `$(e.args[vi].name)` cannot have a default value.")
        for j in vi+1:length(e.args)
            !e.args[j].is_keyword &&
                error("@pyfunc: PtVarArgs must be the last positional argument; " *
                      "`$(e.args[j].name)` follows it.")
        end
    end
    # Keyword-only args without a default are unreachable by name (METH_VARARGS has
    # no kwargs dict). Reject early rather than silently treating them as positional.
    for a in e.args
        a.is_keyword && a.default === nothing &&
            error("@pyfunc: keyword argument `$(a.name)` must have a default value " *
                  "(keyword-only args without defaults are unreachable from Python).")
    end
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

"""
    @pymethod __repr__ fname(p::T)::String = ...
    @pymethod __str__  fname(p::T)::String = ...
    @pymethod __len__  fname(p::T)::Int64  = ...
    @pymethod __hash__ fname(p::T)::Int64  = ...
    @pymethod __bool__ fname(p::T)::Bool   = ...
    @pymethod __getitem__ fname(p::T, i::Int64)::R = ...
    @pymethod __eq__   fname(p::T, other::T)::Bool = ...
    @pymethod __ne__   fname(p::T, other::T)::Bool = ...
    @pymethod __lt__   fname(p::T, other::T)::Bool = ...
    @pymethod __le__   fname(p::T, other::T)::Bool = ...
    @pymethod __gt__   fname(p::T, other::T)::Bool = ...
    @pymethod __ge__   fname(p::T, other::T)::Bool = ...
    @pymethod __new__  fname(a::A, b::B)::T = T(a, b)

Attach a Python dunder method to the `@pyhandle` type `T`. The macro:
  1. Defines the Julia function normally (it remains callable from Julia).
  2. Generates a `Base.@ccallable` entry point via juliac.
  3. Registers the slot on `T`'s Python `PyTypeObject` (overriding the default).

`T` must already be registered with `@pyhandle`. Supported dunders:

| Dunder        | C slot         | Arg signature     | Return type          | Python uses              |
|---------------|----------------|-------------------|----------------------|--------------------------|
| `__repr__`    | `Py_tp_repr`   | `(self::T)`       | `String`             | `repr(obj)`              |
| `__str__`     | `Py_tp_str`    | `(self::T)`       | `String`             | `str(obj)`               |
| `__len__`     | `Py_sq_length` | `(self::T)`       | `Int64`              | `len(obj)`               |
| `__hash__`    | `Py_tp_hash`   | `(self::T)`       | `Int64`              | `hash(obj)`, dict key    |
| `__bool__`    | `Py_nb_bool`   | `(self::T)`       | `Bool`               | `bool(obj)`, `if obj`    |
| `__getitem__` | `Py_sq_item`   | `(self::T, i::Int64)` | any boundary type| `obj[i]` (integer index) |
| `__eq__`      | `Py_tp_richcompare` | `(self::T, other::T)` | `Bool`      | `obj == other` (auto-derives `__ne__`) |
| `__ne__`      | `Py_tp_richcompare` | `(self::T, other::T)` | `Bool`      | `obj != other` (auto-derives `__eq__`) |
| `__lt__`      | `Py_tp_richcompare` | `(self::T, other::T)` | `Bool`      | `obj < other` |
| `__le__`      | `Py_tp_richcompare` | `(self::T, other::T)` | `Bool`      | `obj <= other` |
| `__gt__`      | `Py_tp_richcompare` | `(self::T, other::T)` | `Bool`      | `obj > other` |
| `__ge__`      | `Py_tp_richcompare` | `(self::T, other::T)` | `Bool`      | `obj >= other` |
| `__new__`     | `Py_tp_new`    | `(a::A, b::B)::T` (no self) | `T` (handle type) | `T(a, b)` constructor |

`__getitem__` only handles integer indices (via `Py_sq_item`); slice notation
(`obj[a:b]`) requires `Py_mp_subscript` and is not yet supported.

All six comparison dunders share a single `Py_tp_richcompare` C slot (one
`_pt_richcmp_T` function per handle type). Defining only `__eq__` gives `__ne__`
for free and vice versa. For the ordering ops (`__lt__`/`__le__`/`__gt__`/`__ge__`),
Python handles reflected operations automatically (e.g. `a > b` tries `b.__lt__(a)`
if `a.__gt__(b)` returns `NotImplemented`), so you only need to define the ops you
want. Cross-type comparison always returns `NotImplemented`. Note that Python makes
a type unhashable when `__eq__` is defined without `__hash__`; register
`@pymethod __hash__` as well to retain hashability.
"""
# Named bound-method form: `@pymethod name(self::T, args...)::R = body` (one argument,
# the method name is the function name). Registered in the type's PyMethodDef table so
# Python calls `obj.name(args)`. Returns the macro-expansion Expr.
function _pymethod_named_impl(fundef)
    fname, rawargs, ret_expr = _parse_fundef(fundef)
    (haskey(_PYMETHOD_SLOTS, fname) || fname === :__new__) && error(
        "@pymethod: `$fname` is a dunder — use the two-arg form `@pymethod $fname impl(...)`.")
    isempty(rawargs) && error("@pymethod $fname: needs a `self` argument (self::T).")
    py_name = _default_py_name(string(fname))
    (sname, stype_expr, smut, sdefault, skw) = rawargs[1]
    smut && error("@pymethod $fname: self argument cannot be Mut{…}.")
    sdefault === nothing || error("@pymethod $fname: self argument cannot have a default value.")
    skw && error("@pymethod $fname: self argument cannot be a keyword argument.")
    extra_arg_exprs = Any[]
    for (ename, etype_expr, emut, edefault, ekw) in rawargs[2:end]
        emut && error("@pymethod $fname: argument `$ename` cannot be Mut{…}.")
        edefault === nothing || error("@pymethod $fname: argument `$ename` cannot have a default value.")
        ekw && error("@pymethod $fname: argument `$ename` cannot be a keyword argument.")
        push!(extra_arg_exprs,
              :(ParselTongue.PtArg($(QuoteNode(ename)), $(esc(etype_expr)), false, nothing, false)))
    end
    fname_sym = QuoteNode(fname)
    sname_sym = QuoteNode(sname)
    quote
        $(esc(fundef))
        let _T = $(esc(stype_expr)), _ret = $(esc(ret_expr))
            _self_arg = ParselTongue.PtArg($sname_sym, _T, false, nothing, false)
            _extra = ParselTongue.PtArg[$(extra_arg_exprs...)]
            ParselTongue._register_named_method!(
                ParselTongue.PtNamedMethod(_T, $py_name, $fname_sym, _self_arg, _extra, _ret))
        end
        nothing
    end
end

macro pymethod(arg1, arg2=nothing)
    # One-arg form is a named bound method; two-arg form is a dunder.
    arg2 === nothing && return _pymethod_named_impl(arg1)
    dunder = arg1
    fundef = arg2
    dunder isa Symbol || error(
        "@pymethod: first argument must be a dunder symbol (e.g. __repr__), got: $dunder")

    # __new__ is a class-level factory (no self); handled separately via PtNew.
    if dunder === :__new__
        fname, rawargs, ret_expr = _parse_fundef(fundef)
        fname_sym = QuoteNode(fname)
        arg_exprs = [:(ParselTongue.PtArg($(QuoteNode(n)), $(esc(t)), $mut, $(esc(d)), $kw))
                     for (n, t, mut, d, kw) in rawargs]
        return quote
            $(esc(fundef))
            let _ret = $(esc(ret_expr))
                ParselTongue.ishandle(ParselTongue.c_abi_type(_ret)) ||
                    error(string("@pymethod __new__: return type must be a @pyhandle type, got `", _ret, "`."))
                _args = ParselTongue.PtArg[$(arg_exprs...)]
                for _a in _args
                    ParselTongue.assert_boundary(_a.jl_type)
                end
                ParselTongue._register_new!(ParselTongue.PtNew(_ret, $fname_sym, _args))
            end
            nothing
        end
    end

    if !haskey(_PYMETHOD_SLOTS, dunder)
        supported = join(sort!(collect(string.(keys(_PYMETHOD_SLOTS)))), ", ")
        error("@pymethod: unsupported dunder `$dunder`. Supported: $supported.")
    end

    _extra_spec = get(_PYMETHOD_EXTRA_ARGS, dunder, nothing)
    # n_extra_fixed: exact extra arg count for fixed-arity dunders.
    # n_flex=true: any number ≥1 of extra args (__call__ with :parse_args).
    n_extra_fixed = _extra_spec isa AbstractVector ? length(_extra_spec) :
                    _extra_spec ∈ (:same_handle, :pyobj_val, :numeric_other) ? 1 :
                    _extra_spec === :setitem_val ? 2 :
                    0
    n_flex = _extra_spec === :parse_args

    fname, rawargs, ret_expr = _parse_fundef(fundef)
    if n_flex
        length(rawargs) >= 2 || error(
            "@pymethod $dunder: needs self + at least 1 extra arg, got $(length(rawargs)).")
    else
        n_expected = 1 + n_extra_fixed
        length(rawargs) == n_expected || error(
            "@pymethod $dunder: must have exactly $n_expected argument(s) " *
            "(self" * (n_extra_fixed > 0 ? " + $n_extra_fixed extra" : "") *
            "), got $(length(rawargs)).")
    end

    # Parse and validate self (always rawargs[1]).
    (sname, stype_expr, smut, sdefault, skw) = rawargs[1]
    smut      && error("@pymethod $dunder: self argument cannot be Mut{…}.")
    sdefault !== nothing && error("@pymethod $dunder: self argument cannot have a default value.")
    skw       && error("@pymethod $dunder: self argument cannot be a keyword argument.")

    # Parse extra args (rawargs[2:end]); collect name/type exprs for validation.
    extra_name_exprs = Any[]
    extra_type_exprs = Any[]
    for (ename, etype_expr, emut, edefault, ekw) in rawargs[2:end]
        emut     && error("@pymethod $dunder: extra argument cannot be Mut{…}.")
        edefault !== nothing && error("@pymethod $dunder: extra argument cannot have a default value.")
        ekw      && error("@pymethod $dunder: extra argument cannot be a keyword argument.")
        push!(extra_name_exprs, ename)
        push!(extra_type_exprs, etype_expr)
    end

    dunder_sym = QuoteNode(dunder)
    fname_sym  = QuoteNode(fname)
    sname_sym  = QuoteNode(sname)

    # Build runtime type-equality checks for each extra arg.
    extra_checks = if _extra_spec isa AbstractVector
        expected_extra = _extra_spec
        Expr[
            :($(esc(extra_type_exprs[i])) === $(expected_extra[i]) ||
              error(string("@pymethod ", $dunder_sym, ": extra argument ", $i,
                           " must be typed ::", $(expected_extra[i]),
                           ", got ::", $(esc(extra_type_exprs[i])))))
            for i in 1:n_extra_fixed
        ]
    elseif _extra_spec === :same_handle
        # __eq__ / __ne__ / __lt__ / __le__ / __gt__ / __ge__: second arg == self type.
        Expr[:($(esc(extra_type_exprs[1])) === _T ||
               error(string("@pymethod ", $dunder_sym,
                            ": second argument type must match self type (", _T,
                            "), got ", $(esc(extra_type_exprs[1])))))]
    elseif _extra_spec === :setitem_val
        # __setitem__: first extra arg must be Int64 (index).
        Expr[:($(esc(extra_type_exprs[1])) === Int64 ||
               error(string("@pymethod __setitem__: first extra arg (index) must be ::Int64, got ::",
                            $(esc(extra_type_exprs[1])))))]
    else
        Expr[]
    end

    # Build the extra_args PtArg vector (passed to PtMethod for ccallable/cshim use).
    extra_arg_exprs = [
        :(ParselTongue.PtArg($(QuoteNode(extra_name_exprs[i])), $(esc(extra_type_exprs[i])), false, nothing, false))
        for i in eachindex(extra_name_exprs)
    ]

    quote
        $(esc(fundef))
        let _T = $(esc(stype_expr)), _ret = $(esc(ret_expr))
            $(extra_checks...)
            _self_arg = ParselTongue.PtArg($sname_sym, _T, false, nothing, false)
            _extra_args = ParselTongue.PtArg[$(extra_arg_exprs...)]
            ParselTongue._register_method!(
                ParselTongue.PtMethod(_T, $dunder_sym, $fname_sym, _self_arg, _ret, _extra_args))
        end
        nothing
    end
end

"""
    @pyproperty T propname::ValType (p -> getter_body)

Register a read-only Python property on the `@pyhandle` type `T`. The property
`propname` appears on Python instances as `obj.propname`; it evaluates
`getter_body` with `p` bound to the Julia value.

`ValType` must be a scalar boundary type.

```julia
struct Pt2D; x::Float64; y::Float64; end
@pyhandle Pt2D

@pyproperty Pt2D norm::Float64 (p -> sqrt(p.x^2 + p.y^2))
```
"""
macro pyproperty(T_expr, name_type_expr, getter_lambda)
    name_type_expr isa Expr && name_type_expr.head === :(::) && length(name_type_expr.args) == 2 ||
        error("@pyproperty: second argument must be `propname::ValType` (e.g. norm::Float64), got: $name_type_expr")
    name_sym = name_type_expr.args[1]
    name_sym isa Symbol ||
        error("@pyproperty: property name must be a plain symbol, got: $name_sym")
    val_type_expr = name_type_expr.args[2]

    getter_lambda isa Expr && getter_lambda.head === :-> && length(getter_lambda.args) == 2 ||
        error("@pyproperty: getter must be a lambda (e.g., p -> expr), got: $getter_lambda")
    lambda_arg  = getter_lambda.args[1]
    lambda_body = getter_lambda.args[2]

    # Extract the self symbol from the lambda arg (bare symbol, or symbol::Type).
    self_sym = if lambda_arg isa Symbol
        lambda_arg
    elseif lambda_arg isa Expr && lambda_arg.head === :(::)
        lambda_arg.args[1]
    else
        error("@pyproperty: getter lambda arg must be a symbol (e.g., p -> ...), got: $lambda_arg")
    end

    # Derive a function name from T and the property name.
    T = Core.eval(__module__, T_expr)
    tname = string(T.name.name)
    get_fname = Symbol("_pt_prop_get_$(tname)_$(name_sym)")
    get_fname_sym = QuoteNode(get_fname)
    prop_str = string(name_sym)

    quote
        # Generate the getter function in the user module.
        # esc on the parameter name ensures it binds to the same `p` used in lambda_body.
        function $(esc(get_fname))($(esc(self_sym))::$(esc(T_expr)))::$(esc(val_type_expr))
            $(esc(lambda_body))
        end
        # Register the property.
        let _T = $(esc(T_expr)), _vt = $(esc(val_type_expr))
            ParselTongue.ishandle(ParselTongue.c_abi_type(_T)) ||
                error(string("@pyproperty: type `", _T, "` is not registered with @pyhandle."))
            _vt === Nothing &&
                error("@pyproperty: value type must not be Nothing.")
            try; ParselTongue.c_abi_type(_vt); catch _e
                error(string("@pyproperty: value type `", _vt, "` is not a boundary type: ", _e))
            end
            _T in ParselTongue._HANDLE_TYPES || push!(ParselTongue._HANDLE_TYPES, _T)
            filter!(p -> !(p.handle_type === _T && p.prop_name == $prop_str),
                    ParselTongue._PROPERTIES)
            push!(ParselTongue._PROPERTIES,
                  ParselTongue.PtProperty(_T, $prop_str, $get_fname_sym, nothing, _vt))
        end
        nothing
    end
end
