# ── C PyInit shim generation ──────────────────────────────────────────
#
# Emits `_<mod>module.c`: per-function PyObject<->C-ABI wrappers, the method
# table, the PyModuleDef, and `PyInit_<mod>`. Generated from ParselTongue's own
# export metadata — the shipped 1.12.6 juliac has no `--export-abi`, and we know
# every signature because we generate the `@ccallable` wrappers ourselves.
#
# Marshalling is described per *carrier* type (the C-ABI type a boundary type
# lowers to): scalars, `Cstring`, and `PtBuffer{T}` (1-D numeric arrays).
# Arrays accept any Python buffer (zero-copy in) and return numpy arrays when
# numpy is importable at runtime (else a memoryview) — numpy is never a
# build-time dependency.

# How to receive one Python argument of a given carrier.
struct ArgPlan
    decls::Vector{String}    # C declarations of temporaries
    fmt::String              # PyArg_ParseTuple format units
    addrs::Vector{String}    # address expressions for ParseTuple
    setup::Vector{String}    # runs after ParseTuple, before the call (e.g. GetBuffer)
    callarg::String          # expression passed to the juliac function
    cleanup::Vector{String}  # runs after the call (e.g. PyBuffer_Release)
end
ArgPlan(decls, fmt, addrs, callarg) = ArgPlan(decls, fmt, addrs, String[], callarg, String[])

# How to return a C result of a given carrier as a Python object.
struct RetPlan
    stmts::Vector{String}    # statements; use `r` (the C result), end by returning
end

# ── Scalars ───────────────────────────────────────────────────────────

struct CScalar
    ctype::String
    fmt::String
    tmptype::String
    build::String
    cast::String
end

const _CSCALARS = Dict{Type,CScalar}(
    Int8    => CScalar("int8_t",   "i", "int",                "PyLong_FromLong",             "long"),
    Int16   => CScalar("int16_t",  "i", "int",                "PyLong_FromLong",             "long"),
    Int32   => CScalar("int32_t",  "i", "int",                "PyLong_FromLong",             "long"),
    Int64   => CScalar("int64_t",  "L", "long long",          "PyLong_FromLongLong",         "long long"),
    UInt8   => CScalar("uint8_t",  "I", "unsigned int",       "PyLong_FromUnsignedLong",     "unsigned long"),
    UInt16  => CScalar("uint16_t", "I", "unsigned int",       "PyLong_FromUnsignedLong",     "unsigned long"),
    UInt32  => CScalar("uint32_t", "I", "unsigned int",       "PyLong_FromUnsignedLong",     "unsigned long"),
    UInt64  => CScalar("uint64_t", "K", "unsigned long long", "PyLong_FromUnsignedLongLong", "unsigned long long"),
    Float32 => CScalar("float",    "f", "float",              "PyFloat_FromDouble",          "double"),
    Float64 => CScalar("double",   "d", "double",             "PyFloat_FromDouble",          "double"),
    Bool    => CScalar("bool",     "p", "int",                "PyBool_FromLong",             "long"),
)

isscalar(@nospecialize(C::Type)) = haskey(_CSCALARS, C)

# ── Complex carriers ──────────────────────────────────────────────────
# `Complex{T}` maps to a small `{re; im;}` C struct passed/returned by value.

struct CComplex
    cname::String   # C struct typedef name
    celt::String    # element C type (float / double)
    np::String      # numpy dtype
end

const _CCOMPLEX = Dict{Type,CComplex}(
    ComplexF32 => CComplex("pt_cf32", "float",  "c8"),
    ComplexF64 => CComplex("pt_cf64", "double", "c16"),
)

iscomplex(@nospecialize(C::Type)) = haskey(_CCOMPLEX, C)

# Emit the complex struct typedefs that `exports` actually use (as scalar carriers
# or as array element types). Must precede array structs, which reference them.
function _complex_structs(exports::AbstractVector{PtExport})
    used = Set{Type}()
    for C in _all_carriers(exports)
        iscomplex(C) && push!(used, C)
        isarray(C) && C.parameters[1] in (ComplexF32, ComplexF64) && push!(used, C.parameters[1])
    end
    out = String[]
    ComplexF32 in used && push!(out, "typedef struct { float re, im; } pt_cf32;")
    ComplexF64 in used && push!(out, "typedef struct { double re, im; } pt_cf64;")
    return out
end

# ── Array element info (carrier PtBuffer{T}) ──────────────────────────

struct EltInfo
    ctype::String     # C element type
    np::String        # numpy dtype string
    tag::String       # unique suffix for the C struct typedef
end

const _ELTINFO = Dict{Type,EltInfo}(
    Int8    => EltInfo("int8_t",   "i1", "i8t"),
    Int16   => EltInfo("int16_t",  "i2", "i16"),
    Int32   => EltInfo("int32_t",  "i4", "i32"),
    Int64   => EltInfo("int64_t",  "i8", "i64"),
    UInt8   => EltInfo("uint8_t",  "u1", "u8t"),
    UInt16  => EltInfo("uint16_t", "u2", "u16"),
    UInt32  => EltInfo("uint32_t", "u4", "u32"),
    UInt64  => EltInfo("uint64_t", "u8", "u64"),
    Float32 => EltInfo("float",    "f4", "f32"),
    Float64 => EltInfo("double",   "f8", "f64"),
    ComplexF32 => EltInfo("pt_cf32", "c8",  "c8"),
    ComplexF64 => EltInfo("pt_cf64", "c16", "c16"),
)

isarray(@nospecialize(C::Type)) = C isa DataType && C.name === PtArray.body.body.name
_elt(@nospecialize(C::Type)) = _ELTINFO[C.parameters[1]]      # T from PtArray{T,N}
_ndims(@nospecialize(C::Type)) = C.parameters[2]::Int         # N from PtArray{T,N}
_structname(@nospecialize(C::Type)) = string("PtArray_", _elt(C).tag, "_", _ndims(C))

# ── Tuple carriers (Python tuple returns) ─────────────────────────────
istuple(@nospecialize(C::Type)) = C isa DataType && C <: Tuple

# A short, C-identifier-safe tag per carrier, used to name the tuple struct.
function _carrier_tag(@nospecialize(C::Type))
    isscalar(C) && return replace(_CSCALARS[C].ctype, r"[^A-Za-z0-9]" => "")
    iscomplex(C) && return _CCOMPLEX[C].cname
    C === Cstring && return "str"
    isarray(C) && return _structname(C)
    istuple(C) && return string("T", join((_carrier_tag(S) for S in fieldtypes(C)), ""))
    return "x"
end
_tuple_structname(@nospecialize(C::Type)) =
    string("PtTuple_", join((_carrier_tag(S) for S in fieldtypes(C)), "_"))

# All carrier types used by `exports`, recursing into tuple fields.
function _collect_carriers!(set::Set{Type}, @nospecialize(C::Type))
    push!(set, C)
    if istuple(C)
        for S in fieldtypes(C); _collect_carriers!(set, S); end
    end
    return set
end
function _all_carriers(exports::AbstractVector{PtExport})
    set = Set{Type}()
    for e in exports
        _collect_carriers!(set, c_abi_type(e.ret))
        for a in e.args; _collect_carriers!(set, c_abi_type(a.jl_type)); end
    end
    return set
end

# ── Per-carrier C type / arg / return ─────────────────────────────────

function _c_ctype(@nospecialize(C::Type))
    C === Cvoid && return "void"
    isscalar(C) && return _CSCALARS[C].ctype
    iscomplex(C) && return _CCOMPLEX[C].cname
    C === Cstring && return "char *"
    isarray(C) && return _structname(C)
    istuple(C) && return _tuple_structname(C)
    error("ParselTongue: no C type for carrier `$C`.")
end

# Return a C literal string for a float value (guards against Inf/NaN).
function _c_float_lit(v::Float64)
    isfinite(v) || error("ParselTongue: Inf/NaN default values are not supported.")
    s = string(v)
    # Ensure the string is always parseable as a double (add .0 if no dot/e).
    occursin('.', s) || occursin('e', s) ? s : s * ".0"
end

# Return a C literal string for a scalar default value given its carrier type.
function _c_scalar_lit(@nospecialize(C::Type), val)
    if C === Bool
        return val ? "1" : "0"
    elseif C <: AbstractFloat
        return _c_float_lit(Float64(val))
    else
        return string(Int64(val))
    end
end

function _arg_plan(@nospecialize(C::Type), i::Int; logical::Bool=false, mutable::Bool=false,
                   default::Union{Nothing,Any}=nothing)
    tmp = string("a", i)
    if isscalar(C)
        cs = _CSCALARS[C]
        decl = if default === nothing
            string(cs.tmptype, " ", tmp, ";")
        else
            string(cs.tmptype, " ", tmp, " = (", cs.tmptype, ")", _c_scalar_lit(C, default), ";")
        end
        return ArgPlan([decl], cs.fmt, [string("&", tmp)], string("(", cs.ctype, ")", tmp))
    elseif iscomplex(C)
        cc = _CCOMPLEX[C]; pc = string(tmp, "_pc")
        if default === nothing
            decls = [string("Py_complex ", pc, ";"), string(cc.cname, " ", tmp, ";")]
        else
            v = convert(ComplexF64, default)
            decls = [
                string("Py_complex ", pc, " = {(double)", _c_float_lit(real(v)),
                       ", (double)", _c_float_lit(imag(v)), "};"),
                string(cc.cname, " ", tmp, ";"),
            ]
        end
        setup = [string(tmp, ".re = (", cc.celt, ")", pc, ".real;"),
                 string(tmp, ".im = (", cc.celt, ")", pc, ".imag;")]
        return ArgPlan(decls, "D", [string("&", pc)], setup, tmp, String[])
    elseif C === Cstring
        return ArgPlan([string("const char *", tmp, ";")], "s", [string("&", tmp)],
                       string("(char *)", tmp))
    elseif isarray(C)
        e = _elt(C); sn = _structname(C); n = _ndims(C)
        obj = string(tmp, "_obj"); buf = string(tmp, "_buf")
        decls = [string("PyObject *", obj, ";"), string("Py_buffer ", buf, ";"),
                 string(sn, " ", tmp, ";")]
        bufflags = mutable ? "PyBUF_STRIDES | PyBUF_FORMAT | PyBUF_WRITABLE" :
                             "PyBUF_STRIDES | PyBUF_FORMAT"
        setup = String[
            string("if (PyObject_GetBuffer(", obj, ", &", buf, ", ", bufflags, ") != 0) return NULL;"),
            string("if (", buf, ".ndim != ", n, " || ", buf,
                   ".itemsize != (Py_ssize_t)sizeof(", e.ctype, ")) {"),
            string("    PyBuffer_Release(&", buf, ");"),
            string("    PyErr_SetString(PyExc_TypeError, \"expected a ", n, "-D ", e.np,
                   " array\"); return NULL;"),
            "}",
        ]
        if logical
            # Logical (AbstractArray) policy: C-contiguous only, order always 0.
            append!(setup, [
                string("if (!PyBuffer_IsContiguous(&", buf, ", 'C')) {"),
                string("    PyBuffer_Release(&", buf, ");"),
                "    PyErr_SetString(PyExc_TypeError, \"AbstractArray argument requires a C-contiguous array (try np.ascontiguousarray)\"); return NULL;",
                "}",
                string(tmp, ".order = 0;"),
            ])
        else
            # Dense (Array) policy: accept C- or F-contiguous, record which.
            append!(setup, [
                string("if (PyBuffer_IsContiguous(&", buf, ", 'C')) ", tmp, ".order = 0;"),
                string("else if (PyBuffer_IsContiguous(&", buf, ", 'F')) ", tmp, ".order = 1;"),
                "else {",
                string("    PyBuffer_Release(&", buf, ");"),
                "    PyErr_SetString(PyExc_TypeError, \"expected a contiguous array\"); return NULL;",
                "}",
            ])
        end
        append!(setup, [string(tmp, ".data = (", e.ctype, " *)", buf, ".buf;")])
        for k in 0:n-1
            push!(setup, string(tmp, ".shape[", k, "] = (int64_t)", buf, ".shape[", k, "];"))
        end
        return ArgPlan(decls, "O", [string("&", obj)], setup, tmp,
                       [string("PyBuffer_Release(&", buf, ");")])
    end
    error("ParselTongue: no argument marshalling for carrier `$C`.")
end

# Build a PyObject named `out` from a C value expression `val` of carrier type
# `C`. Array/string builders free their owned memory here, so this is safe to use
# both for a function's whole result and for each field of a tuple result.
function _build_pyobject(@nospecialize(C::Type), val::AbstractString, out::AbstractString)
    if isscalar(C)
        cs = _CSCALARS[C]
        return [string("PyObject *", out, " = ", cs.build, "((", cs.cast, ")", val, ");")]
    elseif iscomplex(C)
        return [string("PyObject *", out, " = PyComplex_FromDoubles((double)", val, ".re, (double)", val, ".im);")]
    elseif C === Cstring
        return [string("PyObject *", out, " = PyUnicode_FromString(", val, ");"),
                string("free((void *)", val, ");")]
    elseif isarray(C)
        e = _elt(C); n = _ndims(C)
        ne = string("nelem_", out); shp = string("shp_", out); nb = string("nbytes_", out)
        stmts = [string("Py_ssize_t ", ne, " = 1;")]
        for k in 0:n-1
            push!(stmts, string(ne, " *= (Py_ssize_t)", val, ".shape[", k, "];"))
        end
        push!(stmts, string("Py_ssize_t ", shp, "[", n, "] = {",
                            join(("(Py_ssize_t)$val.shape[$k]" for k in 0:n-1), ", "), "};"))
        push!(stmts, string("Py_ssize_t ", nb, " = ", ne, " * (Py_ssize_t)sizeof(", e.ctype, ");"))
        # _pt_wrap_ndarray takes ownership of val.data (frees it on error or via _PtBuf).
        push!(stmts, string("PyObject *", out, " = _pt_wrap_ndarray(", val, ".data, ", nb,
                            ", \"", e.np, "\", ", shp, ", ", n, ", ", val, ".order);"))
        return stmts
    end
    error("ParselTongue: no return marshalling for carrier `$C`.")
end

function _ret_plan(@nospecialize(C::Type))
    if C === Cvoid
        return RetPlan(["Py_RETURN_NONE;"])
    elseif istuple(C)
        carriers = fieldtypes(C)
        stmts = String[]; outs = String[]
        for (i, Ci) in enumerate(carriers)
            o = string("o", i)
            append!(stmts, _build_pyobject(Ci, string("r.f", i), o))
            cleanup = join((" Py_XDECREF(o$j);" for j in 1:i-1), "")
            push!(stmts, string("if (!", o, ") {", cleanup, " return NULL; }"))
            push!(outs, o)
        end
        push!(stmts, string("PyObject *rt = PyTuple_Pack(", length(carriers), ", ", join(outs, ", "), ");"))
        for o in outs; push!(stmts, string("Py_DECREF(", o, ");")); end
        push!(stmts, "return rt;")
        return RetPlan(stmts)
    else
        stmts = _build_pyobject(C, "r", "_ret")
        push!(stmts, "return _ret;")
        return RetPlan(stmts)
    end
end

# ── Codegen ───────────────────────────────────────────────────────────

function _extern_decl(e::PtExport)
    ret = _c_ctype(c_abi_type(e.ret))
    user = [_c_ctype(c_abi_type(a.jl_type)) for a in e.args]
    args = join([user..., "int32_t *", "char **"], ", ")
    string("extern ", ret, " ", cabi_symbol(e), "(", args, ");")
end

function _wrapper_fn(e::PtExport)
    wname = string("pyw_", e.export_name)
    io = IOBuffer()
    has_defaults = any(a -> a.default !== nothing, e.args)
    if has_defaults
        println(io, "static PyObject *", wname,
                "(PyObject *self, PyObject *args, PyObject *kwargs) {")
    else
        println(io, "static PyObject *", wname, "(PyObject *self, PyObject *args) {")
    end

    fmt_req = IOBuffer(); fmt_opt = IOBuffer()
    addrs = String[]; callargs = String[]; setups = String[]; cleanups = String[]
    kwnames = String[]
    for (i, a) in enumerate(e.args)
        logical = a.jl_type <: AbstractArray && !(a.jl_type <: Array)
        plan = _arg_plan(c_abi_type(a.jl_type), i; logical, mutable=a.mutable,
                         default=a.default)
        for d in plan.decls; println(io, "    ", d); end
        if a.default === nothing
            print(fmt_req, plan.fmt)
        else
            print(fmt_opt, plan.fmt)
        end
        append!(addrs, plan.addrs); append!(setups, plan.setup); append!(cleanups, plan.cleanup)
        push!(callargs, plan.callarg)
        push!(kwnames, string(a.name))
    end

    fmt_str = String(take!(fmt_req)) * (has_defaults ? "|" * String(take!(fmt_opt)) : "")

    if has_defaults
        # kwlist: all arg names in order, NULL-terminated, declared static.
        kw_entries = join(("\"$n\"" for n in kwnames), ", ")
        println(io, "    static char *_kwlist[] = {", kw_entries, ", NULL};")
        println(io, "    if (!PyArg_ParseTupleAndKeywords(args, kwargs, \"", fmt_str,
                "\", _kwlist", isempty(addrs) ? "" : (", " * join(addrs, ", ")), ")) return NULL;")
    elseif isempty(e.args)
        println(io, "    if (!PyArg_ParseTuple(args, \"\")) return NULL;")
    else
        println(io, "    if (!PyArg_ParseTuple(args, \"", fmt_str, "\", ",
                join(addrs, ", "), ")) return NULL;")
    end
    for s in setups; println(io, "    ", s); end

    println(io, "    int32_t _pt_err = 0;")
    println(io, "    char *_pt_errmsg = NULL;")
    retc = c_abi_type(e.ret)
    err_suffix = isempty(callargs) ? "&_pt_err, &_pt_errmsg" : ", &_pt_err, &_pt_errmsg"
    call_expr = string(cabi_symbol(e), "(", join(callargs, ", "), err_suffix, ")")
    if retc === Cvoid
        println(io, "    Py_BEGIN_ALLOW_THREADS")
        println(io, "    ", call_expr, ";")
        println(io, "    Py_END_ALLOW_THREADS")
    else
        println(io, "    ", _c_ctype(retc), " r;")
        println(io, "    Py_BEGIN_ALLOW_THREADS")
        println(io, "    r = ", call_expr, ";")
        println(io, "    Py_END_ALLOW_THREADS")
    end
    for s in cleanups; println(io, "    ", s); end
    println(io, "    if (_pt_err) {")
    println(io, "        PyErr_SetString(PyExc_RuntimeError, _pt_errmsg ? _pt_errmsg : \"Julia exception\");")
    println(io, "        free(_pt_errmsg);")
    println(io, "        return NULL;")
    println(io, "    }")
    for s in _ret_plan(retc).stmts; println(io, "    ", s); end
    println(io, "}")
    return String(take!(io)), wname
end

# C struct typedefs for every PtArray{T,N} carrier appearing in `exports`.
function _array_structs(exports::AbstractVector{PtExport})
    out = String[]
    for C in _all_carriers(exports)
        if isarray(C)
            ei = _elt(C); n = _ndims(C)
            push!(out, string("typedef struct { ", ei.ctype, " *data; int64_t shape[", n,
                              "]; int32_t order; } ", _structname(C), ";"))
        end
    end
    sort!(out)
    out
end

# Tuple carrier typedefs (Python tuple returns). Emitted after array/complex
# structs, which their fields reference.
function _tuple_structs(exports::AbstractVector{PtExport})
    out = String[]
    for C in _all_carriers(exports)
        if istuple(C)
            fields = join((string(_c_ctype(S), " f", i, ";")
                           for (i, S) in enumerate(fieldtypes(C))), " ")
            push!(out, string("typedef struct { ", fields, " } ", _tuple_structname(C), ";"))
        end
    end
    sort!(out)
    out
end

_uses_arrays(exports) = !isempty(_array_structs(exports))

const _WRAP_ARRAY_HELPER = """
/* _PtBuf: a minimal Python object that owns a malloc'd byte buffer and exposes it
   via the buffer protocol.  numpy.frombuffer() accepts any buffer-protocol object,
   so Julia's result buffer can be handed straight to NumPy without an intermediate
   copy.  When the NumPy array (and therefore this object) is GC'd, the destructor
   calls free().  Initialised by PyInit_<mod> via PyType_Ready. */
typedef struct { PyObject_HEAD void *data; Py_ssize_t len; } _PtBuf;
static void _ptbuf_dealloc(_PtBuf *self) {
    free(self->data);
    Py_TYPE(self)->tp_free((PyObject *)self);
}
static int _ptbuf_getbuf(PyObject *self_, Py_buffer *v, int flags) {
    _PtBuf *self = (_PtBuf *)self_;
    return PyBuffer_FillInfo(v, self_, self->data, self->len, 0, flags);
}
static PyBufferProcs _ptbuf_bufs = { _ptbuf_getbuf, NULL };
static PyTypeObject _PtBufType = {
    PyVarObject_HEAD_INIT(NULL, 0)
    .tp_name      = "parseltongue._PtBuf",
    .tp_basicsize = sizeof(_PtBuf),
    .tp_dealloc   = (destructor)_ptbuf_dealloc,
    .tp_as_buffer = &_ptbuf_bufs,
    .tp_flags     = Py_TPFLAGS_DEFAULT,
    .tp_doc       = "ParselTongue internal: owns a malloc\\'d byte buffer.",
};
/* Create a _PtBuf that takes ownership of `data` (frees it on alloc failure). */
static PyObject *_pt_make_buf(void *data, Py_ssize_t nbytes) {
    _PtBuf *o = PyObject_New(_PtBuf, &_PtBufType);
    if (!o) { free(data); return NULL; }
    o->data = data; o->len = nbytes;
    return (PyObject *)o;
}
/* Wrap a Julia-malloc'd buffer into an N-D NumPy array (zero-copy via _PtBuf),
   or a flat memoryview if NumPy is unavailable.  Takes ownership of `data`. */
static PyObject *_pt_wrap_ndarray(void *data, Py_ssize_t nbytes, const char *dtype,
                                  const Py_ssize_t *shape, int ndim, int order) {
    PyObject *buf = _pt_make_buf(data, nbytes);
    if (!buf) return NULL;
    PyObject *np = PyImport_ImportModule("numpy");
    if (!np) {
        PyErr_Clear();
        PyObject *mv = PyMemoryView_FromObject(buf);
        Py_DECREF(buf);
        return mv;
    }
    PyObject *flat = PyObject_CallMethod(np, "frombuffer", "Os", buf, dtype);
    Py_DECREF(buf);   /* numpy holds ref to buf via flat.base */
    Py_DECREF(np);
    if (!flat) return NULL;
    PyObject *sh = PyTuple_New(ndim);
    if (!sh) { Py_DECREF(flat); return NULL; }
    for (int i = 0; i < ndim; i++)
        PyTuple_SET_ITEM(sh, i, PyLong_FromSsize_t(shape[i]));
    PyObject *kw = Py_BuildValue("{s:s}", "order", order == 1 ? "F" : "C");
    PyObject *args = PyTuple_Pack(1, sh);
    PyObject *reshape = PyObject_GetAttrString(flat, "reshape");
    PyObject *arr = (reshape && args && kw) ? PyObject_Call(reshape, args, kw) : NULL;
    Py_XDECREF(reshape); Py_XDECREF(args); Py_XDECREF(kw); Py_DECREF(sh); Py_DECREF(flat);
    return arr;
}
"""

"""
    emit_cshim(mod_name, exports; doc="") -> String

Return the full C source of the CPython extension module `mod_name` exporting
`exports`. Compile + link with the trimmed `img.a` to get an importable extension.
"""
function emit_cshim(mod_name::AbstractString, exports::AbstractVector{PtExport}; doc::AbstractString="")
    isempty(doc) && (doc = "ParselTongue extension (Julia via juliac --trim)")
    io = IOBuffer()
    println(io, "/* Generated by ParselTongue — do not edit. */")
    println(io, "#define PY_SSIZE_T_CLEAN")
    println(io, "#include <Python.h>")
    println(io, "#include <stdint.h>")
    println(io, "#include <stdbool.h>")
    println(io, "#include <stdlib.h>")
    println(io)
    cstructs = _complex_structs(exports)
    if !isempty(cstructs)
        println(io, "/* C-ABI carriers for complex numbers (match Julia Complex{T}) */")
        for s in cstructs; println(io, s); end
        println(io)
    end
    structs = _array_structs(exports)
    if !isempty(structs)
        println(io, "/* C-ABI carriers for N-D arrays (match Julia PtArray{T,N}) */")
        for s in structs; println(io, s); end
        println(io)
        println(io, _WRAP_ARRAY_HELPER)
    end
    tstructs = _tuple_structs(exports)
    if !isempty(tstructs)
        println(io, "/* C-ABI carriers for tuple returns (match Julia Tuple{...}) */")
        for s in tstructs; println(io, s); end
        println(io)
    end
    println(io, "/* C-ABI entry points emitted by juliac --trim */")
    for e in exports
        println(io, _extern_decl(e))
    end
    println(io)
    wnames = String[]
    for e in exports
        fn, wname = _wrapper_fn(e)
        println(io, fn); println(io)
        push!(wnames, wname)
    end
    println(io, "static PyMethodDef ", mod_name, "_methods[] = {")
    for (e, wname) in zip(exports, wnames)
        has_kw = any(a -> a.default !== nothing, e.args)
        if has_kw
            println(io, "    {\"", e.export_name, "\", (PyCFunction)", wname,
                    ", METH_VARARGS | METH_KEYWORDS, \"", e.export_name, " (Julia)\"},")
        else
            println(io, "    {\"", e.export_name, "\", ", wname, ", METH_VARARGS, \"",
                    e.export_name, " (Julia)\"},")
        end
    end
    println(io, "    {NULL, NULL, 0, NULL}")
    println(io, "};")
    println(io)
    println(io, "static struct PyModuleDef ", mod_name, "_module = {")
    println(io, "    PyModuleDef_HEAD_INIT, \"", mod_name, "\", \"", doc, "\", -1, ", mod_name, "_methods")
    println(io, "};")
    println(io)
    println(io, "PyMODINIT_FUNC PyInit_", mod_name, "(void) {")
    if _uses_arrays(exports)
        println(io, "    if (PyType_Ready(&_PtBufType) < 0) return NULL;")
    end
    println(io, "    /* trimmed Julia lib self-initializes on first @ccallable call */")
    println(io, "    return PyModule_Create(&", mod_name, "_module);")
    println(io, "}")
    return String(take!(io))
end
