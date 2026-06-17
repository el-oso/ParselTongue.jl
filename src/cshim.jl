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

# Escape a Julia string for safe embedding in a C string literal.
_c_escape(s::AbstractString) = replace(replace(s, "\\" => "\\\\"), "\"" => "\\\"")

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

# Emit the complex struct typedefs used by `carriers` (as scalar carriers or as
# array element types). Must precede array structs, which reference them.
function _complex_structs(carriers)
    used = Set{Type}()
    for C in carriers
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
isstrarr(@nospecialize(C::Type)) = C === PtStrArray
ishandle(@nospecialize(C::Type)) = C isa DataType && C.name === PtHandle.body.name
_handle_julia_name(@nospecialize(C::Type)) = string(C.parameters[1].name.name)
ispycallable(@nospecialize(C::Type)) = C === Ptr{Cvoid}
_elt(@nospecialize(C::Type)) = _ELTINFO[C.parameters[1]]      # T from PtArray{T,N}
_ndims(@nospecialize(C::Type)) = C.parameters[2]::Int         # N from PtArray{T,N}
_structname(@nospecialize(C::Type)) = string("PtArray_", _elt(C).tag, "_", _ndims(C))

# Optional (PtOpt{C}) — already defined as isopt/_opt_inner_c in boundary.jl.
# C-level struct name: "PtOpt_double", "PtOpt_int64t", "PtOpt_str", etc.
_opt_cname(@nospecialize(C::Type)) = string("PtOpt_", _carrier_tag(_opt_inner_c(C)))

# Dict carrier (PtDict{V}) — defined in boundary.jl as isdict/_dict_val_c.
# C-level struct name: "PtDict_double", "PtDict_int64t", etc.
_dict_structname(@nospecialize(C::Type)) = string("PtDict_", _carrier_tag(_dict_val_c(C)))

# ── Tuple carriers (Python tuple returns) ─────────────────────────────
istuple(@nospecialize(C::Type)) = C isa DataType && C <: Tuple

# A short, C-identifier-safe tag per carrier, used to name the tuple struct.
function _carrier_tag(@nospecialize(C::Type))
    @match C begin
        GuardBy(isscalar)     => replace(_CSCALARS[C].ctype, r"[^A-Za-z0-9]" => "")
        GuardBy(iscomplex)    => _CCOMPLEX[C].cname
        GuardBy(==(Cstring))  => "str"
        GuardBy(isarray)      => _structname(C)
        GuardBy(isstrarr)     => "stra"
        GuardBy(ishandle)     => string("handle_", _handle_julia_name(C))
        GuardBy(ispycallable) => "pycallable"
        GuardBy(isopt)        => string("opt_", _carrier_tag(_opt_inner_c(C)))
        GuardBy(isdict)       => string("dict_", _carrier_tag(_dict_val_c(C)))
        GuardBy(istuple)      => string("T", join((_carrier_tag(S) for S in fieldtypes(C)), ""))
        _                     => "x"
    end
end
_tuple_structname(@nospecialize(C::Type)) =
    string("PtTuple_", join((_carrier_tag(S) for S in fieldtypes(C)), "_"))

# All carrier types used by `exports`, recursing into tuple fields.
function _collect_carriers!(set::Set{Type}, @nospecialize(C::Type))
    push!(set, C)
    if istuple(C)
        for S in fieldtypes(C); _collect_carriers!(set, S); end
    end
    if isopt(C)
        _collect_carriers!(set, _opt_inner_c(C))
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

# Full carrier set, including the carriers used by @pymethod returns/extra-args,
# @pymethod __new__ constructor args, and @pyproperty value types. Method wrappers
# (emitted inside the handle-type defs) reference these, so their C struct typedefs
# must be emitted before the handle defs.
function _carrier_set(exports::AbstractVector{PtExport},
                      methods::AbstractVector{PtMethod},
                      news::AbstractVector{PtNew},
                      properties::AbstractVector{PtProperty},
                      named_methods::AbstractVector{PtNamedMethod}=PtNamedMethod[])
    set = _all_carriers(exports)
    for m in methods
        _collect_carriers!(set, c_abi_type(m.ret))
        for a in m.extra_args; _collect_carriers!(set, c_abi_type(a.jl_type)); end
    end
    for n in news
        for a in n.args; _collect_carriers!(set, c_abi_type(a.jl_type)); end
    end
    for p in properties
        _collect_carriers!(set, c_abi_type(p.val_type))
    end
    for m in named_methods
        m.ret === Nothing || _collect_carriers!(set, c_abi_type(m.ret))
        for a in m.extra_args; _collect_carriers!(set, c_abi_type(a.jl_type)); end
    end
    return set
end

# ── Per-carrier C type / arg / return ─────────────────────────────────

function _c_ctype(@nospecialize(C::Type))
    @match C begin
        GuardBy(==(Cvoid))    => "void"
        GuardBy(isscalar)     => _CSCALARS[C].ctype
        GuardBy(iscomplex)    => _CCOMPLEX[C].cname
        GuardBy(==(Cstring))  => "char *"
        GuardBy(isarray)      => _structname(C)
        GuardBy(isstrarr)     => "PtStrArray"
        GuardBy(ishandle)     => "PtHandle"
        GuardBy(ispycallable) => "void *"
        GuardBy(isopt)        => _opt_cname(C)
        GuardBy(isdict)       => _dict_structname(C)
        GuardBy(istuple)      => _tuple_structname(C)
        _                     => error("ParselTongue: no C type for carrier `$C`.")
    end
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

# ── Per-carrier argument plan helpers (_ap_*) ─────────────────────────
# Each helper encapsulates one branch of the old _arg_plan if/elseif chain.

function _ap_scalar(tmp::String, @nospecialize(C::Type), default)
    cs = _CSCALARS[C]
    decl = if default === nothing
        string(cs.tmptype, " ", tmp, ";")
    else
        string(cs.tmptype, " ", tmp, " = (", cs.tmptype, ")", _c_scalar_lit(C, default), ";")
    end
    ArgPlan([decl], cs.fmt, [string("&", tmp)], string("(", cs.ctype, ")", tmp))
end

function _ap_complex(tmp::String, @nospecialize(C::Type), abi3::Bool, default)
    cc = _CCOMPLEX[C]
    if abi3
        # Py_complex is not in the Python 3.11 stable ABI; use PyComplex_*AsDouble instead.
        obj = string(tmp, "_obj")
        decls = if default === nothing
            [string("PyObject *", obj, " = NULL;"), string(cc.cname, " ", tmp, ";")]
        else
            v = convert(ComplexF64, default)
            [string("PyObject *", obj, " = NULL;"),
             string(cc.cname, " ", tmp, " = {(", cc.celt, ")", _c_float_lit(real(v)),
                    ", (", cc.celt, ")", _c_float_lit(imag(v)), "};")]
        end
        setup = [
            string("if (", obj, " != NULL) {"),
            string("    ", tmp, ".re = (", cc.celt, ")PyComplex_RealAsDouble(", obj, ");"),
            string("    ", tmp, ".im = (", cc.celt, ")PyComplex_ImagAsDouble(", obj, ");"),
            string("    if (PyErr_Occurred()) return NULL;"),
            string("}"),
        ]
        return ArgPlan(decls, "O", [string("&", obj)], setup, tmp, String[])
    else
        pc = string(tmp, "_pc")
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
    end
end

function _ap_str(tmp::String)
    ArgPlan([string("const char *", tmp, ";")], "s", [string("&", tmp)],
            string("(char *)", tmp))
end

function _ap_stra(tmp::String)
    obj = string(tmp, "_obj"); ni = string(tmp, "_n"); ii = string(tmp, "_i")
    itm = string(tmp, "_itm"); szv = string(tmp, "_sz"); sv = string(tmp, "_sv")
    decls = [string("PyObject *", obj, ";"),
             string("PtStrArray ", tmp, " = {NULL, 0};")]
    setup = String[
        string("if (!PyList_Check(", obj, ")) { PyErr_SetString(PyExc_TypeError, \"expected a list of str\"); return NULL; }"),
        string("{ Py_ssize_t ", ni, " = PyList_Size(", obj, ");"),
        string(tmp, ".data = (char **)malloc(", ni, " > 0 ? (size_t)", ni, " * sizeof(char *) : 1);"),
        string("if (!", tmp, ".data) { PyErr_NoMemory(); return NULL; }"),
        string(tmp, ".len = (int64_t)", ni, ";"),
        string("memset(", tmp, ".data, 0, ", ni, " > 0 ? (size_t)", ni, " * sizeof(char *) : 1);"),
        string("Py_ssize_t ", ii, "; for (", ii, " = 0; ", ii, " < ", ni, "; ", ii, "++) {"),
        string("    PyObject *", itm, " = PyList_GetItem(", obj, ", ", ii, ");"),
        string("    Py_ssize_t ", szv, ";"),
        string("    const char *", sv, " = PyUnicode_AsUTF8AndSize(", itm, ", &", szv, ");"),
        string("    if (!", sv, ") { _pt_free_str_array(", tmp, ".data, ", ii, "); return NULL; }"),
        string("    ", tmp, ".data[", ii, "] = (char *)malloc((size_t)(", szv, " + 1));"),
        string("    if (!", tmp, ".data[", ii, "]) { _pt_free_str_array(", tmp, ".data, ", ii, "); return PyErr_NoMemory(); }"),
        string("    memcpy(", tmp, ".data[", ii, "], ", sv, ", (size_t)(", szv, " + 1)); } }"),
    ]
    cleanup = [string("_pt_free_str_array(", tmp, ".data, ", tmp, ".len);")]
    ArgPlan(decls, "O", [string("&", obj)], setup, tmp, cleanup)
end

function _ap_array(tmp::String, @nospecialize(C::Type), logical::Bool, mutable::Bool)
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
    ArgPlan(decls, "O", [string("&", obj)], setup, tmp,
            [string("PyBuffer_Release(&", buf, ");")])
end

function _ap_handle(tmp::String, tname::String)
    obj = string(tmp, "_obj")
    decls = [
        string("PyObject *", obj, " = NULL;"),
        string("PtHandle ", tmp, ";"),
    ]
    setup = [
        string("if (!PyObject_TypeCheck(", obj, ", (PyTypeObject *)_PtType_", tname, ")) {"),
        string("    PyErr_SetString(PyExc_TypeError, \"expected ", tname, " object\"); return NULL; }"),
        string(tmp, ".ptr = ((_PtObj_", tname, " *)", obj, ")->_data;"),
    ]
    ArgPlan(decls, "O", [string("&", obj)], setup, tmp, String[])
end

function _ap_opt(tmp::String, @nospecialize(C::Type), abi3::Bool)
    inner_C = _opt_inner_c(C)
    ocn = _opt_cname(C)
    obj = string(tmp, "_obj")
    decls = [
        string("PyObject *", obj, " = NULL;"),
        string(ocn, " ", tmp, " = {0};"),
    ]
    # Extract the inner value when the Python object is not None.
    vn = string(tmp, "_v")
    inner_stmts = String[]
    if isscalar(inner_C)
        cs = _CSCALARS[inner_C]
        push!(inner_stmts, string(cs.tmptype, " ", vn, ";"))
        push!(inner_stmts, string("if (!PyArg_Parse(", obj, ", \"", cs.fmt, "\", &", vn, ")) return NULL;"))
        push!(inner_stmts, string(tmp, ".has_value = 1;"))
        push!(inner_stmts, string(tmp, ".value = (", cs.ctype, ")", vn, ";"))
    elseif inner_C === Cstring
        push!(inner_stmts, string("const char *", vn, ";"))
        push!(inner_stmts, string("if (!PyArg_Parse(", obj, ", \"s\", &", vn, ")) return NULL;"))
        push!(inner_stmts, string(tmp, ".has_value = 1;"))
        push!(inner_stmts, string(tmp, ".value = (char *)", vn, ";"))
    else
        error("ParselTongue: Optional inner type `$inner_C` is not yet supported as an argument.")
    end
    setup = String[]
    push!(setup, string("if (", obj, " != NULL && ", obj, " != Py_None) {"))
    for s in inner_stmts; push!(setup, string("    ", s)); end
    push!(setup, "}")
    ArgPlan(decls, "O", [string("&", obj)], setup, tmp, String[])
end

function _ap_dict(tmp::String, @nospecialize(C::Type))
    vc = _dict_val_c(C)
    cs = _CSCALARS[vc]
    dcn = _dict_structname(C)
    obj = string(tmp, "_obj")
    ni = string(tmp, "_n")
    kv = string(tmp, "_k"); vv = string(tmp, "_v")
    pos = string(tmp, "_pos"); ii = string(tmp, "_i")
    klen = string(tmp, "_klen"); ks = string(tmp, "_ks")
    decls = [
        string("PyObject *", obj, " = NULL;"),
        string(dcn, " ", tmp, " = {NULL, NULL, 0};"),
    ]
    vextract = if vc === Bool
        (string("int _vb_", tmp, " = PyObject_IsTrue(", vv, ");"),
         string("if (PyErr_Occurred()) { for (Py_ssize_t _fi = 0; _fi <= ", ii, "; _fi++) free(", tmp, ".keys[_fi]); free(", tmp, ".keys); free(", tmp, ".vals); return NULL; }"),
         string(tmp, ".vals[", ii, "] = (bool)_vb_", tmp, ";"))
    elseif cs.ctype in ("float", "double")
        (string("double _vd_", tmp, " = PyFloat_AsDouble(", vv, ");"),
         string("if (PyErr_Occurred()) { for (Py_ssize_t _fi = 0; _fi <= ", ii, "; _fi++) free(", tmp, ".keys[_fi]); free(", tmp, ".keys); free(", tmp, ".vals); return NULL; }"),
         string(tmp, ".vals[", ii, "] = (", cs.ctype, ")_vd_", tmp, ";"))
    elseif vc in (UInt8, UInt16, UInt32, UInt64)  # unsigned integer
        (string("unsigned long long _vu_", tmp, " = PyLong_AsUnsignedLongLong(", vv, ");"),
         string("if (PyErr_Occurred()) { for (Py_ssize_t _fi = 0; _fi <= ", ii, "; _fi++) free(", tmp, ".keys[_fi]); free(", tmp, ".keys); free(", tmp, ".vals); return NULL; }"),
         string(tmp, ".vals[", ii, "] = (", cs.ctype, ")_vu_", tmp, ";"))
    else  # signed integer
        (string("long long _vs_", tmp, " = PyLong_AsLongLong(", vv, ");"),
         string("if (PyErr_Occurred()) { for (Py_ssize_t _fi = 0; _fi <= ", ii, "; _fi++) free(", tmp, ".keys[_fi]); free(", tmp, ".keys); free(", tmp, ".vals); return NULL; }"),
         string(tmp, ".vals[", ii, "] = (", cs.ctype, ")_vs_", tmp, ";"))
    end
    setup = String[
        string("if (!PyDict_Check(", obj, ")) { PyErr_SetString(PyExc_TypeError, \"expected a dict[str, ...]\"); return NULL; }"),
        string("Py_ssize_t ", ni, " = PyDict_Size(", obj, ");"),
        string(tmp, ".keys = (char **)malloc(", ni, " > 0 ? (size_t)", ni, " * sizeof(char *) : 1);"),
        string(tmp, ".vals = (", cs.ctype, " *)malloc(", ni, " > 0 ? (size_t)", ni, " * sizeof(", cs.ctype, ") : 1);"),
        string("if (!", tmp, ".keys || !", tmp, ".vals) { free(", tmp, ".keys); free(", tmp, ".vals); PyErr_NoMemory(); return NULL; }"),
        string(tmp, ".len = (int64_t)", ni, ";"),
        string("memset(", tmp, ".keys, 0, ", ni, " > 0 ? (size_t)", ni, " * sizeof(char *) : 1);"),
        string("{ PyObject *", kv, ", *", vv, "; Py_ssize_t ", pos, " = 0, ", ii, " = 0;"),
        string("while (PyDict_Next(", obj, ", &", pos, ", &", kv, ", &", vv, ")) {"),
        string("    Py_ssize_t ", klen, "; const char *", ks, " = PyUnicode_AsUTF8AndSize(", kv, ", &", klen, ");"),
        string("    if (!", ks, ") { for (Py_ssize_t _fi = 0; _fi < ", ii, "; _fi++) free(", tmp, ".keys[_fi]); free(", tmp, ".keys); free(", tmp, ".vals); return NULL; }"),
        string("    ", tmp, ".keys[", ii, "] = (char *)malloc((size_t)(", klen, " + 1));"),
        string("    if (!", tmp, ".keys[", ii, "]) { for (Py_ssize_t _fi = 0; _fi <= ", ii, "; _fi++) free(", tmp, ".keys[_fi]); free(", tmp, ".keys); free(", tmp, ".vals); PyErr_NoMemory(); return NULL; }"),
        string("    memcpy(", tmp, ".keys[", ii, "], ", ks, ", (size_t)(", klen, " + 1));"),
        vextract[1], vextract[2], vextract[3],
        string("    ", ii, "++;"),
        "} }",
    ]
    # No cleanup needed: Julia's from_c frees keys, vals, and each key string.
    ArgPlan(decls, "O", [string("&", obj)], setup, tmp, String[])
end

function _ap_pycallable(tmp::String)
    obj = string(tmp, "_obj")
    decls = [
        string("PyObject *", obj, " = NULL;"),
        string("void *", tmp, " = NULL;"),
    ]
    setup = [
        string("if (!PyCallable_Check(", obj, ")) { PyErr_SetString(PyExc_TypeError, \"argument must be callable\"); return NULL; }"),
        string("Py_INCREF(", obj, ");"),
        string(tmp, " = (void *)", obj, ";"),
    ]
    # Py_DECREF after Julia call; also inserted before return NULL in later setup steps.
    cleanup = [string("Py_DECREF((PyObject *)", tmp, ");")]
    ArgPlan(decls, "O", [string("&", obj)], setup, tmp, cleanup)
end

function _arg_plan(@nospecialize(C::Type), i::Int; logical::Bool=false, mutable::Bool=false,
                   default::Union{Nothing,Any}=nothing, abi3::Bool=false)
    tmp = string("a", i)
    @match C begin
        GuardBy(isscalar)     => _ap_scalar(tmp, C, default)
        GuardBy(iscomplex)    => _ap_complex(tmp, C, abi3, default)
        GuardBy(==(Cstring))  => _ap_str(tmp)
        GuardBy(isstrarr)     => _ap_stra(tmp)
        GuardBy(isarray)      => _ap_array(tmp, C, logical, mutable)
        GuardBy(ishandle)     => _ap_handle(tmp, _handle_julia_name(C))
        GuardBy(isopt)        => _ap_opt(tmp, C, abi3)
        GuardBy(isdict)       => _ap_dict(tmp, C)
        GuardBy(ispycallable) => _ap_pycallable(tmp)
        _                     => error("ParselTongue: no argument marshalling for carrier `$C`.")
    end
end

# ── Per-carrier return plan helpers (_bp_*) ────────────────────────────
# Each helper encapsulates one branch of the old _build_pyobject if/elseif chain.
# Array/string builders free their owned memory; safe for single-result and tuple fields.

function _bp_scalar(@nospecialize(C::Type), val::AbstractString, out::AbstractString)
    cs = _CSCALARS[C]
    [string("PyObject *", out, " = ", cs.build, "((", cs.cast, ")", val, ");")]
end

function _bp_complex(val::AbstractString, out::AbstractString)
    [string("PyObject *", out, " = PyComplex_FromDoubles((double)", val, ".re, (double)", val, ".im);")]
end

function _bp_str(val::AbstractString, out::AbstractString)
    [string("PyObject *", out, " = PyUnicode_FromString(", val, ");"),
     string("free((void *)", val, ");")]
end

function _bp_stra(val::AbstractString, out::AbstractString)
    [string("PyObject *", out, " = _pt_strarray_to_list(", val, ".data, ", val, ".len);")]
end

function _bp_handle(@nospecialize(C::Type), val::AbstractString, out::AbstractString)
    tname = _handle_julia_name(C)
    [string("PyObject *", out, " = _pt_make_obj_", tname, "(", val, ");")]
end

function _bp_pycallable(val::AbstractString, out::AbstractString)
    [string("PyObject *", out, " = (PyObject *)", val, ";"),
     string("if (", out, ") { Py_INCREF(", out, "); }")]
end

function _bp_array(@nospecialize(C::Type), val::AbstractString, out::AbstractString)
    e = _elt(C); n = _ndims(C)
    # 1-D UInt8 arrays return a Python `bytes` object (the natural Python type for
    # binary data). All other arrays return a NumPy array via _pt_wrap_ndarray.
    if e.ctype == "uint8_t" && n == 1
        nb = string("nbytes_", out)
        return String[
            string("Py_ssize_t ", nb, " = (Py_ssize_t)", val, ".shape[0];"),
            string("PyObject *", out, " = _pt_make_bytes((void *)", val, ".data, ", nb, ");"),
        ]
    end
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
    stmts
end

function _bp_opt(@nospecialize(C::Type), val::AbstractString, out::AbstractString)
    inner_C = _opt_inner_c(C)
    if isscalar(inner_C)
        cs = _CSCALARS[inner_C]
        inner_build = string(cs.build, "((", cs.cast, ")", val, ".value)")
    elseif inner_C === Cstring
        inner_build = string("PyUnicode_FromString(", val, ".value); free((void *)", val, ".value)")
    else
        error("ParselTongue: Optional return with inner type `$inner_C` is not yet supported.")
    end
    String[
        string("PyObject *", out, " = NULL;"),
        string("if (!", val, ".has_value) { Py_INCREF(Py_None); ", out, " = Py_None; }"),
        string("else { ", out, " = ", inner_build, "; }"),
    ]
end

function _bp_dict(@nospecialize(C::Type), val::AbstractString, out::AbstractString)
    vc = _dict_val_c(C)
    cs = _CSCALARS[vc]
    ii = string("_di_", out); vobj = string("_dv_", out)
    vbuild = if vc === Bool
        string("PyBool_FromLong((long)", val, ".vals[", ii, "])")
    elseif cs.ctype in ("float", "double")
        string("PyFloat_FromDouble((double)", val, ".vals[", ii, "])")
    else
        string("PyLong_FromLongLong((long long)", val, ".vals[", ii, "])")
    end
    String[
        string("PyObject *", out, " = PyDict_New();"),
        string("for (int64_t ", ii, " = 0; ", ii, " < ", val, ".len; ", ii, "++) {"),
        string("    PyObject *", vobj, " = ", vbuild, ";"),
        string("    if (!", vobj, " || PyDict_SetItemString(", out, ", ", val, ".keys[", ii, "], ", vobj, ") < 0) {"),
        string("        Py_XDECREF(", vobj, ");"),
        string("        for (int64_t _fj = ", ii, " + 1; _fj < ", val, ".len; _fj++) free(", val, ".keys[_fj]);"),
        string("        Py_DECREF(", out, "); ", out, " = NULL; break;"),
        "    }",
        string("    Py_DECREF(", vobj, "); free(", val, ".keys[", ii, "]);"),
        "}",
        string("free(", val, ".keys); free(", val, ".vals);"),
    ]
end

# Build a PyObject named `out` from a C value expression `val` of carrier type `C`.
function _build_pyobject(@nospecialize(C::Type), val::AbstractString, out::AbstractString)
    @match C begin
        GuardBy(isscalar)     => _bp_scalar(C, val, out)
        GuardBy(iscomplex)    => _bp_complex(val, out)
        GuardBy(==(Cstring))  => _bp_str(val, out)
        GuardBy(isstrarr)     => _bp_stra(val, out)
        GuardBy(ishandle)     => _bp_handle(C, val, out)
        GuardBy(ispycallable) => _bp_pycallable(val, out)
        GuardBy(isarray)      => _bp_array(C, val, out)
        GuardBy(isopt)        => _bp_opt(C, val, out)
        GuardBy(isdict)       => _bp_dict(C, val, out)
        _                     => error("ParselTongue: no return marshalling for carrier `$C`.")
    end
end

function _ret_plan(@nospecialize(C::Type); @nospecialize(jl_type::Type=Any))
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
        if jl_type <: NamedTuple
            # NamedTuple → Python dict{str, Any}
            names = fieldnames(jl_type)
            decref_all = join((string(" Py_DECREF(", oi, ");") for oi in outs), "")
            push!(stmts, string("PyObject *rt = PyDict_New(); if (!rt) {", decref_all, " return NULL; }"))
            for (i, (nm, o)) in enumerate(zip(names, outs))
                # On SetItemString failure: decref remaining (unowned) objects + the dict.
                remaining = join((string(" Py_DECREF(", oi, ");") for oi in outs[i:end]), "")
                push!(stmts, string("if (PyDict_SetItemString(rt, \"", nm, "\", ", o, ") < 0) {",
                                    remaining, " Py_DECREF(rt); return NULL; }"))
                push!(stmts, string("Py_DECREF(", o, ");"))
            end
        else
            push!(stmts, string("PyObject *rt = PyTuple_Pack(", length(carriers), ", ", join(outs, ", "), ");"))
            for o in outs; push!(stmts, string("Py_DECREF(", o, ");")); end
        end
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

# Emit `static PyObject *pt_err_<Name> = NULL;` globals for each registered error.
function _error_globals(errors::AbstractVector{PtError})
    isempty(errors) && return String[]
    return [string("static PyObject *pt_err_", e.py_name, " = NULL;") for e in errors]
end

# Emit PyErr_NewException + PyModule_AddObject calls for PyInit_<mod>.
function _error_inits(mod_name::AbstractString, errors::AbstractVector{PtError})
    isempty(errors) && return String[]
    stmts = String[]
    for e in errors
        gname = string("pt_err_", e.py_name)
        push!(stmts, string(gname, " = PyErr_NewException(\"", mod_name, ".", e.py_name,
                            "\", ", e.parent, ", NULL);"))
        push!(stmts, string("if (!", gname, ") { Py_DECREF(m); return NULL; }"))
        push!(stmts, string("Py_INCREF(", gname, ");"))
        push!(stmts, string("if (PyModule_AddObject(m, \"", e.py_name, "\", ", gname,
                            ") < 0) { Py_DECREF(", gname, "); Py_DECREF(m); return NULL; }"))
    end
    return stmts
end

# Insert `cleanups` statements before each `return NULL;` (or PyErr_NoMemory) in a
# single setup line, so that resources acquired by earlier args are released on failure.
# Handles two patterns: bare `if (COND) return NULL;` (wrapped with braces) and
# embedded `return NULL;` inside an existing brace block (simple textual insertion).
function _insert_cleanup_before_return(s::String, cleanups::Vector{String})
    isempty(cleanups) && return s
    (contains(s, "return NULL;") || contains(s, "return PyErr_NoMemory();")) || return s
    cl = join(cleanups, " ")
    m = match(r"^(if\s*\(.+\))\s+return NULL;$", s)
    m !== nothing && return "$(m.captures[1]) { $cl return NULL; }"
    s = replace(s, "return NULL;" => cl * " return NULL;")
    s = replace(s, "return PyErr_NoMemory();" => cl * " return PyErr_NoMemory();")
    return s
end

function _wrapper_fn_varargs(e::PtExport; errors::Vector{PtError}=PtError[], abi3::Bool=false)
    va_idx = something(findfirst(a -> isvarargs(a.jl_type), e.args))
    T_elt  = _varargs_elt(e.args[va_idx].jl_type)
    ei     = _ELTINFO[T_elt]
    cs     = _CSCALARS[T_elt]
    fixed_args = e.args[1:va_idx-1]
    kw_args    = e.args[va_idx+1:end]   # all must have is_keyword=true
    n_fixed    = length(fixed_args)
    va_name    = string("a", va_idx)
    has_kw     = !isempty(kw_args)

    wname = string("pyw_", e.export_name)
    io = IOBuffer()
    if has_kw
        println(io, "static PyObject *", wname,
                "(PyObject *self, PyObject *args, PyObject *kwargs) {")
    else
        println(io, "static PyObject *", wname, "(PyObject *self, PyObject *args) {")
    end

    # Declarations for fixed positional args.
    fixed_plans = ArgPlan[]
    for (i, a) in enumerate(fixed_args)
        logical = a.jl_type <: AbstractArray && !(a.jl_type <: Array)
        plan = _arg_plan(c_abi_type(a.jl_type), i; logical, mutable=a.mutable,
                         default=nothing, abi3)
        push!(fixed_plans, plan)
        for d in plan.decls; println(io, "    ", d); end
    end

    # Varargs buffer pointer + carrier struct.
    println(io, "    ", ei.ctype, " *_va_data = NULL;")
    sn_va = _structname(PtArray{T_elt,1})
    println(io, "    ", sn_va, " ", va_name, ";")
    println(io, "    Py_ssize_t _nargs = PyTuple_GET_SIZE(args);")

    # Declarations for keyword-only args.
    kw_plans = ArgPlan[]
    for (i, a) in enumerate(kw_args)
        logical = a.jl_type <: AbstractArray && !(a.jl_type <: Array)
        plan = _arg_plan(c_abi_type(a.jl_type), va_idx + i; logical, mutable=a.mutable,
                         default=a.default, abi3)
        push!(kw_plans, plan)
        for d in plan.decls; println(io, "    ", d); end
    end

    # Minimum positional arg count check.
    if n_fixed > 0
        println(io, "    if (_nargs < ", n_fixed, ") {")
        println(io, "        PyErr_Format(PyExc_TypeError,")
        println(io, "            \"expected at least ", n_fixed,
                " positional argument(s), got %zd\", (Py_ssize_t)_nargs);")
        println(io, "        return NULL;")
        println(io, "    }")
    end

    # Extract each fixed positional arg via PyArg_Parse on the individual tuple item.
    # Track acquired buffer cleanups so failures release previously-acquired resources.
    fixed_cleanups = String[]
    for (i, (plan, _)) in enumerate(zip(fixed_plans, fixed_args))
        parg = string("_parg_", i)
        println(io, "    PyObject *", parg, " = PyTuple_GET_ITEM(args, ", i - 1, ");")
        addr_str = isempty(plan.addrs) ? "" : ", " * join(plan.addrs, ", ")
        println(io, "    if (!PyArg_Parse(", parg, ", \"", plan.fmt, "\"", addr_str, ")) return NULL;")
        for s in plan.setup
            println(io, "    ", _insert_cleanup_before_return(s, fixed_cleanups))
        end
        append!(fixed_cleanups, plan.cleanup)
    end

    # Parse keyword-only args using ParseTupleAndKeywords with an empty positional tuple.
    if has_kw
        kw_fmt_req = IOBuffer(); kw_fmt_opt = IOBuffer()
        kw_addrs = String[]; kwnames = String[]
        for (plan, a) in zip(kw_plans, kw_args)
            if a.default === nothing
                print(kw_fmt_req, plan.fmt)
            else
                print(kw_fmt_opt, plan.fmt)
            end
            append!(kw_addrs, plan.addrs)
            push!(kwnames, string(a.name))
        end
        kw_fmt_str = String(take!(kw_fmt_req)) * "|" * String(take!(kw_fmt_opt))
        kw_entries = join(("\"$n\"" for n in kwnames), ", ")
        fc_str = isempty(fixed_cleanups) ? "" : " " * join(fixed_cleanups, " ")
        println(io, "    { static char *_kwlist[] = {", kw_entries, ", NULL};")
        println(io, "      PyObject *_empty_args = PyTuple_New(0);")
        println(io, "      if (!_empty_args) {", fc_str, " return NULL; }")
        addr_str = isempty(kw_addrs) ? "" : ", " * join(kw_addrs, ", ")
        println(io, "      int _kw_ok = PyArg_ParseTupleAndKeywords(_empty_args, kwargs,")
        println(io, "          \"", kw_fmt_str, "\", _kwlist", addr_str, ");")
        println(io, "      Py_DECREF(_empty_args);")
        println(io, "      if (!_kw_ok) {", fc_str, " return NULL; }")
        println(io, "    }")
        for (plan, _) in zip(kw_plans, kw_args)
            for s in plan.setup; println(io, "    ", s); end
        end
    end

    # Build varargs array: malloc, loop over remaining tuple items, extract scalars.
    fc_str = isempty(fixed_cleanups) ? "" : join(fixed_cleanups, " ") * " "
    println(io, "    Py_ssize_t _nva = _nargs - ", n_fixed, ";")
    println(io, "    _va_data = (", ei.ctype,
            " *)malloc(_nva > 0 ? (size_t)_nva * sizeof(", ei.ctype, ") : 1);")
    println(io, "    if (!_va_data) { ", fc_str, "return PyErr_NoMemory(); }")
    println(io, "    for (Py_ssize_t _vi = 0; _vi < _nva; _vi++) {")
    println(io, "        PyObject *_vobj = PyTuple_GET_ITEM(args, ", n_fixed, " + _vi);")
    println(io, "        ", cs.tmptype, " _vtmp;")
    println(io, "        if (!PyArg_Parse(_vobj, \"", cs.fmt, "\", &_vtmp))")
    println(io, "            { ", fc_str, "free(_va_data); return NULL; }")
    println(io, "        _va_data[_vi] = (", cs.ctype, ")_vtmp;")
    println(io, "    }")
    println(io, "    ", va_name, ".data = _va_data;")
    println(io, "    ", va_name, ".shape[0] = (int64_t)_nva;")
    println(io, "    ", va_name, ".order = 1;")

    # Build callargs: fixed positional, then varargs carrier, then kw args.
    callargs = String[]
    for plan in fixed_plans; push!(callargs, plan.callarg); end
    push!(callargs, va_name)
    for plan in kw_plans;    push!(callargs, plan.callarg); end

    kw_cleanups  = vcat([plan.cleanup for plan in kw_plans]...)
    all_cleanups = vcat(fixed_cleanups, kw_cleanups)

    println(io, "    int32_t _pt_err = 0;")
    println(io, "    char *_pt_errmsg = NULL;")
    retc = c_abi_type(e.ret)
    call_expr = string(cabi_symbol(e), "(", join(callargs, ", "), ", &_pt_err, &_pt_errmsg)")
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
    for s in all_cleanups; println(io, "    ", s); end
    println(io, "    free(_va_data);")
    println(io, "    if (_pt_err) {")
    println(io, "        const char *_msg = _pt_errmsg ? _pt_errmsg : \"Julia exception\";")
    if isempty(errors)
        println(io, "        PyErr_SetString(PyExc_RuntimeError, _msg);")
    else
        for (i, err) in enumerate(errors)
            kw = i == 1 ? "if" : "else if"
            println(io, "        $kw (_pt_err == ", i + 1, ")")
            println(io, "            PyErr_SetString(pt_err_", err.py_name, ", _msg);")
        end
        println(io, "        else")
        println(io, "            PyErr_SetString(PyExc_RuntimeError, _msg);")
    end
    println(io, "        free(_pt_errmsg);")
    println(io, "        return NULL;")
    println(io, "    }")
    for s in _ret_plan(retc; jl_type=e.ret).stmts; println(io, "    ", s); end
    println(io, "}")
    return String(take!(io)), wname
end

function _wrapper_fn(e::PtExport; errors::Vector{PtError}=PtError[], abi3::Bool=false)
    any(a -> isvarargs(a.jl_type), e.args) && return _wrapper_fn_varargs(e; errors, abi3)
    wname = string("pyw_", e.export_name)
    io = IOBuffer()
    has_kw = any(a -> a.default !== nothing || a.is_keyword, e.args)
    if has_kw
        println(io, "static PyObject *", wname,
                "(PyObject *self, PyObject *args, PyObject *kwargs) {")
    else
        println(io, "static PyObject *", wname, "(PyObject *self, PyObject *args) {")
    end

    fmt_req = IOBuffer(); fmt_opt = IOBuffer()
    addrs = String[]; callargs = String[]; cleanups = String[]
    kwnames = String[]
    per_arg_setups   = Vector{String}[]
    per_arg_cleanups = Vector{String}[]
    for (i, a) in enumerate(e.args)
        logical = a.jl_type <: AbstractArray && !(a.jl_type <: Array)
        plan = _arg_plan(c_abi_type(a.jl_type), i; logical, mutable=a.mutable,
                         default=a.default, abi3)
        for d in plan.decls; println(io, "    ", d); end
        if a.default === nothing
            print(fmt_req, plan.fmt)
        else
            print(fmt_opt, plan.fmt)
        end
        append!(addrs, plan.addrs); append!(cleanups, plan.cleanup)
        push!(per_arg_setups, plan.setup)
        push!(per_arg_cleanups, plan.cleanup)
        push!(callargs, plan.callarg)
        push!(kwnames, string(a.name))
    end

    fmt_str = String(take!(fmt_req)) * (has_kw ? "|" * String(take!(fmt_opt)) : "")

    if has_kw
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
    # Emit setups arg-by-arg, inserting accumulated release calls before return-NULL so
    # that a failure in arg i properly releases resources acquired by args 0..i-1.
    acquired = String[]
    for (slist, clist) in zip(per_arg_setups, per_arg_cleanups)
        for s in slist
            println(io, "    ", _insert_cleanup_before_return(s, acquired))
        end
        append!(acquired, clist)
    end

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
    println(io, "        const char *_msg = _pt_errmsg ? _pt_errmsg : \"Julia exception\";")
    if isempty(errors)
        println(io, "        PyErr_SetString(PyExc_RuntimeError, _msg);")
    else
        # Error codes: 1=RuntimeError, 2=errors[1], 3=errors[2], ...
        for (i, err) in enumerate(errors)
            kw = i == 1 ? "if" : "else if"
            println(io, "        $kw (_pt_err == ", i + 1, ")")
            println(io, "            PyErr_SetString(pt_err_", err.py_name, ", _msg);")
        end
        println(io, "        else")
        println(io, "            PyErr_SetString(PyExc_RuntimeError, _msg);")
    end
    println(io, "        free(_pt_errmsg);")
    println(io, "        return NULL;")
    println(io, "    }")
    for s in _ret_plan(retc; jl_type=e.ret).stmts; println(io, "    ", s); end
    println(io, "}")
    return String(take!(io)), wname
end

# C struct typedefs for every PtArray{T,N} carrier appearing in `exports`.
function _array_structs(carriers)
    out = String[]
    for C in carriers
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
function _tuple_structs(carriers)
    out = String[]
    for C in carriers
        if istuple(C)
            fields = join((string(_c_ctype(S), " f", i, ";")
                           for (i, S) in enumerate(fieldtypes(C))), " ")
            push!(out, string("typedef struct { ", fields, " } ", _tuple_structname(C), ";"))
        end
    end
    sort!(out)
    out
end

# Optional carrier typedefs. Must come after complex/scalar type declarations
# since the inner type's C name is used here.
function _opt_structs(carriers)
    out = String[]
    seen = Set{Type}()
    for C in carriers
        if isopt(C) && C ∉ seen
            push!(seen, C)
            inner_C = _opt_inner_c(C)
            push!(out, string("typedef struct { int32_t has_value; ", _c_ctype(inner_C),
                              " value; } ", _opt_cname(C), ";"))
        end
    end
    sort!(out)
    return out
end

# Dict carrier typedefs.
function _dict_structs(carriers)
    out = String[]
    seen = Set{Type}()
    for C in carriers
        if isdict(C) && C ∉ seen
            push!(seen, C)
            vc = _dict_val_c(C)
            push!(out, string("typedef struct { char **keys; ", _c_ctype(vc),
                              " *vals; int64_t len; } ", _dict_structname(C), ";"))
        end
    end
    sort!(out)
    return out
end

_uses_arrays(carriers) = any(isarray, carriers)
function _carrier_is_bytes(@nospecialize(C::Type))
    C === PtArray{UInt8,1} ||
    (isopt(C) && _opt_inner_c(C) === PtArray{UInt8,1}) ||
    (istuple(C) && any(S -> S === PtArray{UInt8,1}, fieldtypes(C)))
end
_uses_bytes(exports) = any(e -> _carrier_is_bytes(c_abi_type(e.ret)), exports)

function _carrier_is_strarr(@nospecialize(C::Type))
    isstrarr(C) ||
    (isopt(C) && isstrarr(_opt_inner_c(C))) ||
    (istuple(C) && any(isstrarr, fieldtypes(C)))
end
_uses_strarr(exports) = any(e -> any(a -> isstrarr(c_abi_type(a.jl_type)), e.args) ||
                                  _carrier_is_strarr(c_abi_type(e.ret)), exports)

function _carrier_is_handle(@nospecialize(C::Type))
    ishandle(C) ||
    (isopt(C) && ishandle(_opt_inner_c(C))) ||
    (istuple(C) && any(ishandle, fieldtypes(C)))
end
_uses_handles(exports) = any(e -> _carrier_is_handle(c_abi_type(e.ret)) ||
                                   any(a -> ishandle(c_abi_type(a.jl_type)), e.args),
                             exports)

const _WRAP_BYTES_HELPER = """
/* _pt_make_bytes: wrap a Julia-malloc'd byte buffer as a Python bytes object.
   Copies data into an immutable bytes object, then frees the buffer. */
static PyObject *_pt_make_bytes(void *data, Py_ssize_t n) {
    PyObject *b = PyBytes_FromStringAndSize((const char *)data, n);
    free(data);
    return b;
}
"""

const _WRAP_STRARR_HELPER = """
/* PtStrArray: carrier for Vector{String} <-> list[str]. */
typedef struct { char **data; int64_t len; } PtStrArray;
/* Free all strings + the pointer array (null entries skipped). */
static void _pt_free_str_array(char **data, int64_t len) {
    for (int64_t i = 0; i < len; i++) if (data[i]) free(data[i]);
    free(data);
}
/* Build a Python list from a Julia-malloc'd string array. Takes ownership
   of data (frees each element and the array on success and error). */
static PyObject *_pt_strarray_to_list(char **data, int64_t len) {
    PyObject *lst = PyList_New((Py_ssize_t)len);
    if (!lst) { _pt_free_str_array(data, len); return NULL; }
    for (int64_t i = 0; i < len; i++) {
        PyObject *s = PyUnicode_FromString(data[i]);
        free(data[i]);
        if (!s) {
            for (int64_t j = i + 1; j < len; j++) free(data[j]);
            free(data);
            Py_DECREF(lst);
            return NULL;
        }
        PyList_SetItem(lst, (Py_ssize_t)i, s);
    }
    free(data);
    return lst;
}
"""

const _PTHANDLE_TYPEDEF = """
/* PtHandle: C-ABI carrier for @pyhandle types (parameterized in Julia, type-erased in C). */
typedef struct { void *ptr; } PtHandle;
"""

# Emit the `tp_new` C slot for one @pyhandle type that has a `@pymethod __new__`.
# Reuses _arg_plan for argument parsing (same machinery as _wrapper_fn).
function _emit_tp_new_slot(io::IO, tname::String, n::PtNew; abi3::Bool=false)
    sym  = cabi_symbol(n)
    args = n.args
    plans = [_arg_plan(c_abi_type(a.jl_type), i; abi3) for (i, a) in enumerate(args)]
    # extern declaration for the Julia ccallable
    arg_ctypes = [_c_ctype(c_abi_type(a.jl_type)) for a in args]
    all_params = join([arg_ctypes..., "int32_t *", "char **"], ", ")
    println(io, "extern PtHandle $(sym)($(all_params));")
    # tp_new slot function
    println(io, "static PyObject *_pt_new_$(tname)(PyTypeObject *type, PyObject *args, PyObject *kw) {")
    println(io, "    (void)kw;")
    for plan in plans
        for d in plan.decls; println(io, "    ", d); end
    end
    fmt = join([p.fmt for p in plans])
    addrs_list = vcat([p.addrs for p in plans]...)
    if isempty(args)
        println(io, "    if (!PyArg_ParseTuple(args, \"\")) return NULL;")
    else
        println(io, "    if (!PyArg_ParseTuple(args, \"$(fmt)\", ",
                join(addrs_list, ", "), ")) return NULL;")
    end
    for plan in plans
        for s in plan.setup; println(io, "    ", s); end
    end
    callargs = join([p.callarg for p in plans], ", ")
    err_sep  = isempty(args) ? "" : ", "
    println(io, "    int32_t _pt_err = 0; char *_pt_errmsg = NULL;")
    println(io, "    PtHandle h = $(sym)($(callargs)$(err_sep)&_pt_err, &_pt_errmsg);")
    for plan in plans
        for s in plan.cleanup; println(io, "    ", s); end
    end
    println(io, "    if (_pt_err) {")
    println(io, "        PyErr_SetString(PyExc_RuntimeError,")
    println(io, "            _pt_errmsg ? _pt_errmsg : \"error in constructor\");")
    println(io, "        free(_pt_errmsg);")
    println(io, "        return NULL;")
    println(io, "    }")
    println(io, "    return _pt_make_obj_$(tname)(h);")
    println(io, "}")
end

# Emit the C `PyCFunction` (METH_VARARGS) wrapper for a bound named method
# `obj.name(args)`. Self handle + tuple-parsed args → Julia ccallable → boxed return.
function _emit_named_method_wrapper(io::IO, tname::String, m::PtNamedMethod)
    sym   = cabi_symbol(m)
    plans = [_arg_plan(c_abi_type(a.jl_type), i) for (i, a) in enumerate(m.extra_args)]
    arg_ctypes = [_c_ctype(c_abi_type(a.jl_type)) for a in m.extra_args]
    is_void = m.ret === Nothing
    ret_c   = is_void ? Cvoid : c_abi_type(m.ret)
    ret_ct  = is_void ? "void" : _c_ctype(ret_c)
    extern_params = join(["PtHandle", arg_ctypes..., "int32_t *", "char **"], ", ")
    println(io, "extern $ret_ct $(sym)($extern_params);")
    println(io, "static PyObject *_pt_namedwrap_$(tname)_$(m.py_name)(PyObject *self, PyObject *args) {")
    println(io, "    PtHandle h = { ((_PtObj_$(tname) *)self)->_data };")
    for plan in plans
        for d in plan.decls; println(io, "    ", d); end
    end
    fmt = join([p.fmt for p in plans])
    addrs_list = vcat([p.addrs for p in plans]...)
    if isempty(plans)
        println(io, "    if (!PyArg_ParseTuple(args, \"\")) return NULL;")
    else
        println(io, "    if (!PyArg_ParseTuple(args, \"$(fmt)\", ", join(addrs_list, ", "), ")) return NULL;")
    end
    for plan in plans
        for s in plan.setup; println(io, "    ", s); end
    end
    callargs = join([p.callarg for p in plans], ", ")
    err_sep  = isempty(plans) ? "" : ", "
    println(io, "    int32_t _err = 0; char *_errmsg = NULL;")
    if is_void
        println(io, "    $(sym)(h$(err_sep)$(callargs), &_err, &_errmsg);")
    else
        println(io, "    $ret_ct r = $(sym)(h$(err_sep)$(callargs), &_err, &_errmsg);")
    end
    for plan in plans
        for s in plan.cleanup; println(io, "    ", s); end
    end
    println(io, "    if (_err) {")
    println(io, "        PyErr_SetString(PyExc_RuntimeError, _errmsg ? _errmsg : \"error in $(m.py_name)\");")
    println(io, "        free(_errmsg);")
    println(io, "        return NULL;")
    println(io, "    }")
    if is_void
        println(io, "    Py_RETURN_NONE;")
    else
        for s in _build_pyobject(ret_c, "r", "_result"); println(io, "    ", s); end
        println(io, "    return _result;")
    end
    println(io, "}")
end

# Emit per-type C structs, destructors, PyType_Spec, make-object helpers.
# Each @pyhandle T gets a proper PyTypeObject so Python sees `mod.T` as a real class.
# `methods` is the full list of PtMethod registrations; dunders for T are injected
# as custom slots (overriding the generated defaults where applicable).
# `news` is the list of PtNew registrations; a matching entry adds a tp_new slot.
function _emit_handle_type_defs(io::IO, mod_name::AbstractString,
                                handle_types::AbstractVector{<:Type},
                                methods::AbstractVector{PtMethod}=PtMethod[],
                                news::AbstractVector{PtNew}=PtNew[];
                                mutable_types::AbstractVector{<:Type}=Type[],
                                mutable_struct_types::AbstractVector{<:Type}=Type[],
                                properties::AbstractVector{PtProperty}=PtProperty[],
                                named_methods::AbstractVector{PtNamedMethod}=PtNamedMethod[])
    isempty(handle_types) && return
    println(io, "/* @pyhandle types: each becomes a real Python class (isinstance, repr, etc.) */")
    for T in handle_types
        tname  = string(T.name.name)
        tmeths = filter(m -> m.handle_type === T, methods)
        tnew_i = findfirst(n -> n.handle_type === T, news)
        tnew   = tnew_i === nothing ? nothing : news[tnew_i]
        # @pymutable types store a registry id in _data and route dealloc / field
        # access through Julia rather than raw C memory.
        is_mut_struct = T in mutable_struct_types

        println(io, "typedef struct { PyObject_HEAD void *_data; } _PtObj_$tname;")
        # Declare early so _pt_richcmp_T (emitted below) can reference it.
        println(io, "static PyObject *_PtType_$tname = NULL;")
        # Forward-declare _pt_make_obj_T so _pt_new_T (emitted below) can call it.
        println(io, "static PyObject *_pt_make_obj_$tname(PtHandle);")
        if is_mut_struct
            # Drop the registry reference (lets Julia GC the object); _data is the id.
            println(io, "extern void _pt_dealloc_$(tname)_jl(PtHandle);")
            println(io, "static void _pt_dealloc_$tname(PyObject *self) {")
            println(io, "    PtHandle h = { ((_PtObj_$tname *)self)->_data };")
            println(io, "    _pt_dealloc_$(tname)_jl(h);")
            println(io, "    PyObject_Free(self);")
            println(io, "}")
        else
            println(io, "static void _pt_dealloc_$tname(PyObject *self) {")
            println(io, "    free(((_PtObj_$tname *)self)->_data);")
            println(io, "    PyObject_Free(self);")
            println(io, "}")
        end

        # For each @pymethod, emit a C slot wrapper. The wrapper kind is
        # determined by the dunder and/or its Julia return type.
        for m in tmeths
            # These are handled via separate code paths below.
            m.dunder ∈ (:__eq__, :__ne__, :__lt__, :__le__, :__gt__, :__ge__) && continue
            m.dunder ∈ (:__enter__, :__exit__) && continue  # PyMethodDef table
            (is_numeric_binary(m.dunder) || is_numeric_reflected(m.dunder)) && continue  # grouped Py_nb_* wrapper
            clean = replace(replace(string(m.dunder), r"^__" => ""), r"__$" => "")
            sym   = cabi_symbol(m)
            dname = string(m.dunder)

            if m.dunder === :__getitem__
                # ssizeargfunc: PyObject* (*)(PyObject*, Py_ssize_t)
                ret_c = c_abi_type(m.ret)
                c_ret_type = _c_ctype(ret_c)
                box_stmts  = _build_pyobject(ret_c, "r", "_result")
                println(io, "extern $c_ret_type $(sym)(PtHandle, int64_t, int32_t *, char **);")
                println(io, "static PyObject *_pt_slot_$(tname)_$(clean)(PyObject *self, Py_ssize_t idx) {")
                println(io, "    _PtObj_$(tname) *obj = (_PtObj_$(tname) *)self;")
                println(io, "    PtHandle h = { obj->_data };")
                println(io, "    int32_t _err = 0; char *_errmsg = NULL;")
                println(io, "    $c_ret_type r = $(sym)(h, (int64_t)idx, &_err, &_errmsg);")
                println(io, "    if (_err) {")
                println(io, "        PyErr_SetString(PyExc_RuntimeError,")
                println(io, "            _errmsg ? _errmsg : \"error in $dname\");")
                println(io, "        free(_errmsg);")
                println(io, "        return NULL;")
                println(io, "    }")
                for s in box_stmts; println(io, "    ", s); end
                println(io, "    return _result;")
                println(io, "}")

            elseif m.dunder === :__setitem__
                # ssizeobjargproc: int (*)(PyObject*, Py_ssize_t, PyObject*)
                # Unbox the value using PyArg_Parse with the format char from _CSCALARS.
                val_T  = m.extra_args[2].jl_type
                val_cs = _CSCALARS[val_T]
                println(io, "extern void $(sym)(PtHandle, int64_t, $(val_cs.ctype), int32_t *, char **);")
                println(io, "static int _pt_slot_$(tname)_$(clean)(PyObject *self, Py_ssize_t idx, PyObject *val) {")
                println(io, "    if (val == NULL) {")
                println(io, "        PyErr_SetString(PyExc_TypeError, \"$tname does not support item deletion\");")
                println(io, "        return -1;")
                println(io, "    }")
                println(io, "    _PtObj_$(tname) *obj = (_PtObj_$(tname) *)self;")
                println(io, "    PtHandle h = { obj->_data };")
                println(io, "    $(val_cs.tmptype) _tmp;")
                println(io, "    if (!PyArg_Parse(val, \"$(val_cs.fmt)\", &_tmp)) return -1;")
                println(io, "    $(val_cs.ctype) _v = ($(val_cs.ctype))_tmp;")
                println(io, "    int32_t _err = 0; char *_errmsg = NULL;")
                println(io, "    $(sym)(h, (int64_t)idx, _v, &_err, &_errmsg);")
                println(io, "    if (_err) {")
                println(io, "        PyErr_SetString(PyExc_RuntimeError,")
                println(io, "            _errmsg ? _errmsg : \"error in $dname\");")
                println(io, "        free(_errmsg);")
                println(io, "        return -1;")
                println(io, "    }")
                println(io, "    return 0;")
                println(io, "}")

            elseif m.dunder === :__contains__
                # objobjproc: int (*)(PyObject*, PyObject*)
                val_T  = m.extra_args[1].jl_type
                val_cs = _CSCALARS[val_T]
                println(io, "extern int8_t $(sym)(PtHandle, $(val_cs.ctype), int32_t *, char **);")
                println(io, "static int _pt_slot_$(tname)_$(clean)(PyObject *self, PyObject *other) {")
                println(io, "    _PtObj_$(tname) *obj = (_PtObj_$(tname) *)self;")
                println(io, "    PtHandle h = { obj->_data };")
                println(io, "    $(val_cs.tmptype) _tmp;")
                println(io, "    if (!PyArg_Parse(other, \"$(val_cs.fmt)\", &_tmp)) return -1;")
                println(io, "    $(val_cs.ctype) _v = ($(val_cs.ctype))_tmp;")
                println(io, "    int32_t _err = 0; char *_errmsg = NULL;")
                println(io, "    int8_t r = $(sym)(h, _v, &_err, &_errmsg);")
                println(io, "    if (_err) {")
                println(io, "        PyErr_SetString(PyExc_RuntimeError,")
                println(io, "            _errmsg ? _errmsg : \"error in $dname\");")
                println(io, "        free(_errmsg);")
                println(io, "        return -1;")
                println(io, "    }")
                println(io, "    return r ? 1 : 0;")
                println(io, "}")

            elseif m.dunder === :__call__
                # ternaryfunc: PyObject* (*)(PyObject*, PyObject*, PyObject*)
                # Parse extra args from the positional args tuple.
                plans = [_arg_plan(c_abi_type(a.jl_type), i) for (i, a) in enumerate(m.extra_args)]
                arg_ctypes = [_c_ctype(c_abi_type(a.jl_type)) for a in m.extra_args]
                all_extern_params = join(["PtHandle", arg_ctypes..., "int32_t *", "char **"], ", ")
                ret_c = c_abi_type(m.ret)
                c_ret_type = _c_ctype(ret_c)
                box_stmts  = _build_pyobject(ret_c, "r", "_result")
                println(io, "extern $c_ret_type $(sym)($all_extern_params);")
                println(io, "static PyObject *_pt_slot_$(tname)_$(clean)(PyObject *self, PyObject *args, PyObject *kw) {")
                println(io, "    (void)kw;")
                println(io, "    _PtObj_$(tname) *obj = (_PtObj_$(tname) *)self;")
                println(io, "    PtHandle h = { obj->_data };")
                for plan in plans
                    for d in plan.decls; println(io, "    ", d); end
                end
                fmt = join([p.fmt for p in plans])
                addrs_list = vcat([p.addrs for p in plans]...)
                if isempty(plans)
                    println(io, "    if (!PyArg_ParseTuple(args, \"\")) return NULL;")
                else
                    println(io, "    if (!PyArg_ParseTuple(args, \"$(fmt)\", ",
                            join(addrs_list, ", "), ")) return NULL;")
                end
                for plan in plans
                    for s in plan.setup; println(io, "    ", s); end
                end
                callargs = join([p.callarg for p in plans], ", ")
                err_sep  = isempty(plans) ? "" : ", "
                println(io, "    int32_t _err = 0; char *_errmsg = NULL;")
                println(io, "    $c_ret_type r = $(sym)(h$(err_sep)$(callargs), &_err, &_errmsg);")
                for plan in plans
                    for s in plan.cleanup; println(io, "    ", s); end
                end
                println(io, "    if (_err) {")
                println(io, "        PyErr_SetString(PyExc_RuntimeError,")
                println(io, "            _errmsg ? _errmsg : \"error in $dname\");")
                println(io, "        free(_errmsg);")
                println(io, "        return NULL;")
                println(io, "    }")
                for s in box_stmts; println(io, "    ", s); end
                println(io, "    return _result;")
                println(io, "}")

            elseif m.dunder === :__iter__
                # getiterfunc: PyObject* (*)(PyObject*) — self-return (Py_INCREF + return self).
                println(io, "static PyObject *_pt_slot_$(tname)_$(clean)(PyObject *self) {")
                println(io, "    Py_INCREF(self);")
                println(io, "    return self;")
                println(io, "}")

            elseif m.dunder === :__next__
                # iternextfunc: PyObject* (*)(PyObject*). Return is Union{V,Nothing}
                # (a PtOpt carrier); has_value==0 → raise StopIteration. For @pymutable
                # iterators the Julia body advances state in-place.
                ret_c   = c_abi_type(m.ret)
                opt_c   = _c_ctype(ret_c)                 # PtOpt_<tag>
                inner_C = _opt_inner_c(ret_c)
                box_stmts = _build_pyobject(inner_C, "r.value", "_result")
                println(io, "extern $opt_c $(sym)(PtHandle, int32_t *, char **);")
                println(io, "static PyObject *_pt_slot_$(tname)_$(clean)(PyObject *self) {")
                println(io, "    PtHandle h = { ((_PtObj_$tname *)self)->_data };")
                println(io, "    int32_t _err = 0; char *_errmsg = NULL;")
                println(io, "    $opt_c r = $(sym)(h, &_err, &_errmsg);")
                println(io, "    if (_err) {")
                println(io, "        PyErr_SetString(PyExc_RuntimeError,")
                println(io, "            _errmsg ? _errmsg : \"error in $dname\");")
                println(io, "        free(_errmsg);")
                println(io, "        return NULL;")
                println(io, "    }")
                println(io, "    if (!r.has_value) { PyErr_SetNone(PyExc_StopIteration); return NULL; }")
                for s in box_stmts; println(io, "    ", s); end
                println(io, "    return _result;")
                println(io, "}")

            elseif is_numeric_unary(m.dunder)
                # Unary number slot: unaryfunc PyObject* (*)(PyObject*).
                ret_c = c_abi_type(m.ret)
                c_ret_type = _c_ctype(ret_c)
                box_stmts  = _build_pyobject(ret_c, "r", "_result")
                println(io, "extern $c_ret_type $(sym)(PtHandle, int32_t *, char **);")
                println(io, "static PyObject *_pt_slot_$(tname)_$(clean)(PyObject *self) {")
                println(io, "    PtHandle h = { ((_PtObj_$tname *)self)->_data };")
                println(io, "    int32_t _err = 0; char *_errmsg = NULL;")
                println(io, "    $c_ret_type r = $(sym)(h, &_err, &_errmsg);")
                println(io, "    if (_err) {")
                println(io, "        PyErr_SetString(PyExc_RuntimeError,")
                println(io, "            _errmsg ? _errmsg : \"error in $dname\");")
                println(io, "        free(_errmsg);")
                println(io, "        return NULL;")
                println(io, "    }")
                for s in box_stmts; println(io, "    ", s); end
                println(io, "    return _result;")
                println(io, "}")

            elseif m.ret === String
                # String return (repr/str pattern): char* → PyUnicode_FromString.
                println(io, "extern char *$(sym)(PtHandle, int32_t *, char **);")
                println(io, "static PyObject *_pt_slot_$(tname)_$(clean)(PyObject *self) {")
                println(io, "    _PtObj_$(tname) *obj = (_PtObj_$(tname) *)self;")
                println(io, "    PtHandle h = { obj->_data };")
                println(io, "    int32_t _err = 0; char *_errmsg = NULL;")
                println(io, "    char *r = $(sym)(h, &_err, &_errmsg);")
                println(io, "    if (_err) {")
                println(io, "        PyErr_SetString(PyExc_RuntimeError,")
                println(io, "            _errmsg ? _errmsg : \"error in $dname\");")
                println(io, "        free(_errmsg);")
                println(io, "        return NULL;")
                println(io, "    }")
                println(io, "    PyObject *result = PyUnicode_FromString(r);")
                println(io, "    free(r);")
                println(io, "    return result;")
                println(io, "}")

            elseif m.ret === Int64
                # Integer return (len/hash pattern): int64_t → Py_ssize_t / Py_hash_t.
                cret = m.dunder === :__len__ ? "Py_ssize_t" : "Py_hash_t"
                println(io, "extern int64_t $(sym)(PtHandle, int32_t *, char **);")
                println(io, "static $cret _pt_slot_$(tname)_$(clean)(PyObject *self) {")
                println(io, "    _PtObj_$(tname) *obj = (_PtObj_$(tname) *)self;")
                println(io, "    PtHandle h = { obj->_data };")
                println(io, "    int32_t _err = 0; char *_errmsg = NULL;")
                println(io, "    int64_t r = $(sym)(h, &_err, &_errmsg);")
                println(io, "    if (_err) {")
                println(io, "        PyErr_SetString(PyExc_RuntimeError,")
                println(io, "            _errmsg ? _errmsg : \"error in $dname\");")
                println(io, "        free(_errmsg);")
                println(io, "        return ($cret)(-1);")
                println(io, "    }")
                println(io, "    return ($cret)r;")
                println(io, "}")

            elseif m.ret === Bool
                # Bool return (bool/contains pattern): int8_t → int.
                println(io, "extern int8_t $(sym)(PtHandle, int32_t *, char **);")
                println(io, "static int _pt_slot_$(tname)_$(clean)(PyObject *self) {")
                println(io, "    _PtObj_$(tname) *obj = (_PtObj_$(tname) *)self;")
                println(io, "    PtHandle h = { obj->_data };")
                println(io, "    int32_t _err = 0; char *_errmsg = NULL;")
                println(io, "    int8_t r = $(sym)(h, &_err, &_errmsg);")
                println(io, "    if (_err) {")
                println(io, "        PyErr_SetString(PyExc_RuntimeError,")
                println(io, "            _errmsg ? _errmsg : \"error in $dname\");")
                println(io, "        free(_errmsg);")
                println(io, "        return -1;")
                println(io, "    }")
                println(io, "    return r ? 1 : 0;")
                println(io, "}")
            end
        end

        # All six comparison dunders → a single Py_tp_richcompare slot wrapper.
        # One _pt_richcmp_T function dispatches on `op`. __eq__ / __ne__ are
        # auto-derived from each other (negation) if only one is registered.
        # Ordering ops (lt/le/gt/ge) return NotImplemented when not registered;
        # Python handles the reflected operation (e.g. a>b → b.__lt__(a)).
        # Cross-type comparison always returns Py_RETURN_NOTIMPLEMENTED.
        _cmp_all = [(:__lt__,"Py_LT"),(:__le__,"Py_LE"),(:__eq__,"Py_EQ"),
                    (:__ne__,"Py_NE"),(:__gt__,"Py_GT"),(:__ge__,"Py_GE")]
        cmp_idx  = Dict(d => findfirst(m -> m.dunder === d, tmeths) for (d,_) in _cmp_all)
        has_richcmp = any(!isnothing, values(cmp_idx))
        if has_richcmp
            # extern declarations for registered ops
            for (d, _) in _cmp_all
                i = cmp_idx[d]; isnothing(i) && continue
                println(io, "extern int8_t $(cabi_symbol(tmeths[i]))(PtHandle, PtHandle, int32_t *, char **);")
            end
            println(io, "static PyObject *_pt_richcmp_$(tname)(PyObject *self, PyObject *other, int op) {")
            println(io, "    if (Py_TYPE(other) != (PyTypeObject *)_PtType_$tname) Py_RETURN_NOTIMPLEMENTED;")
            println(io, "    PtHandle h_s = { ((_PtObj_$tname *)self)->_data };")
            println(io, "    PtHandle h_o = { ((_PtObj_$tname *)other)->_data };")
            println(io, "    int32_t _err = 0; char *_errmsg = NULL;")
            println(io, "    int8_t r;")
            # Build branches: each entry = (py_op, sym_to_call, negate, err_msg).
            # __eq__ auto-derives from __ne__ and vice versa; ordering ops don't
            # auto-derive (Python handles the reflected op at the interpreter level).
            branches = Tuple{String,String,Bool,String}[]
            for (d, py_op) in _cmp_all
                dname = string(d)
                i = cmp_idx[d]
                if !isnothing(i)
                    push!(branches, (py_op, cabi_symbol(tmeths[i]), false, "error in $dname"))
                elseif d === :__ne__ && !isnothing(cmp_idx[:__eq__])
                    push!(branches, (py_op, cabi_symbol(tmeths[cmp_idx[:__eq__]]), true, "error in __eq__"))
                elseif d === :__eq__ && !isnothing(cmp_idx[:__ne__])
                    push!(branches, (py_op, cabi_symbol(tmeths[cmp_idx[:__ne__]]), true, "error in __ne__"))
                end
            end
            for (i, (py_op, sym, negate, err_msg)) in enumerate(branches)
                kw = i == 1 ? "if" : "} else if"
                println(io, "    $kw (op == $py_op) {")
                println(io, "        r = $sym(h_s, h_o, &_err, &_errmsg);")
                println(io, "        if (_err) { PyErr_SetString(PyExc_RuntimeError, _errmsg ? _errmsg : \"$err_msg\"); free(_errmsg); return NULL; }")
                negate && println(io, "        r = !r;")
            end
            println(io, "    } else {")
            println(io, "        Py_RETURN_NOTIMPLEMENTED;")
            println(io, "    }")
            println(io, "    return PyBool_FromLong((long)r);")
            println(io, "}")
        end

        # Numeric binary ops (+ reflected) → one combined wrapper per Py_nb_* slot,
        # dispatching on operand types so `vec*2.0` and `2.0*vec` both work. A forward
        # op (`__mul__`) may be T×T or T×scalar; a reflected op (`__rmul__`) is scalar×T.
        # On a scalar-parse failure we PyErr_Clear + fall through → NotImplemented, so
        # Python can try the other operand's method (correct mixed-type fallback).
        numbin = filter(m -> is_numeric_binary(m.dunder) || is_numeric_reflected(m.dunder), tmeths)
        numbin_slots = unique([_PYMETHOD_SLOTS[m.dunder].slot for m in numbin])
        # Emits: declare _result via the call, err-check, box, return — indented `pad`.
        _emit_nb_arm = function (sym, mret, callargs, dname, pad)
            rc = c_abi_type(mret)
            println(io, pad, _c_ctype(rc), " r = ", sym, "(", callargs, ", &_err, &_errmsg);")
            println(io, pad, "if (_err) { PyErr_SetString(PyExc_RuntimeError, _errmsg ? _errmsg : \"error in ", dname, "\"); free(_errmsg); return NULL; }")
            for s in _build_pyobject(rc, "r", "_result"); println(io, pad, s); end
            println(io, pad, "return _result;")
        end
        for slot in numbin_slots
            nbtag = replace(slot, "Py_" => "")          # e.g. "nb_add"
            wname = "_pt_$(nbtag)_$(tname)"
            fwd_i  = findfirst(m -> is_numeric_binary(m.dunder)    && _PYMETHOD_SLOTS[m.dunder].slot == slot, numbin)
            refl_i = findfirst(m -> is_numeric_reflected(m.dunder) && _PYMETHOD_SLOTS[m.dunder].slot == slot, numbin)
            fwd  = fwd_i  === nothing ? nothing : numbin[fwd_i]
            refl = refl_i === nothing ? nothing : numbin[refl_i]
            is_pow = slot == "Py_nb_power"
            # extern decls for the registered ccallables (other carrier = handle or scalar).
            for mm in (fwd, refl)
                mm === nothing && continue
                oc = _c_ctype(c_abi_type(mm.extra_args[1].jl_type))
                println(io, "extern $(_c_ctype(c_abi_type(mm.ret))) $(cabi_symbol(mm))(PtHandle, $oc, int32_t *, char **);")
            end
            sig = is_pow ? "(PyObject *a, PyObject *b, PyObject *_mod)" : "(PyObject *a, PyObject *b)"
            println(io, "static PyObject *$wname$sig {")
            is_pow && println(io, "    (void)_mod;")
            println(io, "    int _ah = Py_TYPE(a) == (PyTypeObject *)_PtType_$tname; (void)_ah;")
            println(io, "    int _bh = Py_TYPE(b) == (PyTypeObject *)_PtType_$tname; (void)_bh;")
            println(io, "    int32_t _err = 0; char *_errmsg = NULL;")
            if fwd !== nothing
                fsym = cabi_symbol(fwd)
                fother = fwd.extra_args[1].jl_type
                if fother === T
                    println(io, "    if (_ah && _bh) {")
                    println(io, "        PtHandle _ha = { ((_PtObj_$tname *)a)->_data };")
                    println(io, "        PtHandle _hb = { ((_PtObj_$tname *)b)->_data };")
                    _emit_nb_arm(fsym, fwd.ret, "_ha, _hb", string(fwd.dunder), "        ")
                    println(io, "    }")
                else
                    cs = _CSCALARS[fother]
                    println(io, "    if (_ah) {")
                    println(io, "        $(cs.tmptype) _sb;")
                    println(io, "        if (PyArg_Parse(b, \"$(cs.fmt)\", &_sb)) {")
                    println(io, "            PtHandle _ha = { ((_PtObj_$tname *)a)->_data };")
                    _emit_nb_arm(fsym, fwd.ret, "_ha, ($(cs.ctype))_sb", string(fwd.dunder), "            ")
                    println(io, "        }")
                    println(io, "        PyErr_Clear();")
                    println(io, "    }")
                end
            end
            if refl !== nothing
                rsym = cabi_symbol(refl)
                cs = _CSCALARS[refl.extra_args[1].jl_type]
                println(io, "    if (_bh) {")
                println(io, "        $(cs.tmptype) _sa;")
                println(io, "        if (PyArg_Parse(a, \"$(cs.fmt)\", &_sa)) {")
                println(io, "            PtHandle _hb = { ((_PtObj_$tname *)b)->_data };")
                _emit_nb_arm(rsym, refl.ret, "_hb, ($(cs.ctype))_sa", string(refl.dunder), "            ")
                println(io, "        }")
                println(io, "        PyErr_Clear();")
                println(io, "    }")
            end
            println(io, "    Py_RETURN_NOTIMPLEMENTED;")
            println(io, "}")
        end

        # Default repr (used when no @pymethod __repr__ is registered).
        has_repr = any(m -> m.dunder === :__repr__, tmeths)
        if !has_repr
            println(io, "static PyObject *_pt_repr_$tname(PyObject *self) {")
            println(io, "    return PyUnicode_FromString(\"<$tname>\");")
            println(io, "}")
        end

        # Auto field access (item K): expose each scalar field as a read-only
        # Python attribute via Py_tp_getattro. Field bytes are read at the Julia
        # struct offset (isbits layout == C layout) and converted with the same
        # scalar→PyObject builders used for return values. Non-scalar fields and
        # all dunders fall through to PyObject_GenericGetAttr (so repr/__class__
        # etc. keep working). PyUnicode_CompareWithASCIIString is stable-ABI safe.
        if is_mut_struct
            # @pymutable field access: read/write through Julia per-field accessors
            # (fields may be String etc., not just isbits — no raw memory layout).
            bfields = _pymut_accessor_fields(T)
            has_getattr = !isempty(bfields)
            has_setattr = !isempty(bfields)
            if has_getattr
                for (fname, FT) in bfields
                    println(io, "extern $(_c_ctype(c_abi_type(FT))) pt_field_get_$(tname)_$(fname)(PtHandle, int32_t *, char **);")
                end
                println(io, "static PyObject *_pt_getattr_$tname(PyObject *self, PyObject *name) {")
                println(io, "    PtHandle h = { ((_PtObj_$tname *)self)->_data };")
                for (fname, FT) in bfields
                    fc = c_abi_type(FT)
                    box_stmts = _build_pyobject(fc, "r", "_result")
                    println(io, "    if (PyUnicode_CompareWithASCIIString(name, \"$fname\") == 0) {")
                    println(io, "        int32_t _err = 0; char *_errmsg = NULL;")
                    println(io, "        $(_c_ctype(fc)) r = pt_field_get_$(tname)_$(fname)(h, &_err, &_errmsg);")
                    println(io, "        if (_err) { PyErr_SetString(PyExc_RuntimeError, _errmsg ? _errmsg : \"error reading $fname\"); free(_errmsg); return NULL; }")
                    for s in box_stmts; println(io, "        ", s); end
                    println(io, "        return _result;")
                    println(io, "    }")
                end
                println(io, "    return PyObject_GenericGetAttr(self, name);")
                println(io, "}")
            end
            if has_setattr
                for (fname, FT) in bfields
                    println(io, "extern void pt_field_set_$(tname)_$(fname)(PtHandle, $(_c_ctype(c_abi_type(FT))), int32_t *, char **);")
                end
                println(io, "static int _pt_setattr_$(tname)(PyObject *self, PyObject *name, PyObject *value) {")
                println(io, "    if (value == NULL) {")
                println(io, "        PyErr_SetString(PyExc_TypeError, \"cannot delete $tname attribute\");")
                println(io, "        return -1;")
                println(io, "    }")
                println(io, "    PtHandle h = { ((_PtObj_$(tname) *)self)->_data };")
                for (fname, FT) in bfields
                    println(io, "    if (PyUnicode_CompareWithASCIIString(name, \"$fname\") == 0) {")
                    if FT === String
                        # Parse a Python str into a borrowed const char*; the ccallable
                        # copies it into a Julia String, so no lifetime issue.
                        println(io, "        const char *_s;")
                        println(io, "        if (!PyArg_Parse(value, \"s\", &_s)) return -1;")
                        println(io, "        int32_t _err = 0; char *_errmsg = NULL;")
                        println(io, "        pt_field_set_$(tname)_$(fname)(h, (char *)_s, &_err, &_errmsg);")
                    else
                        cs = _CSCALARS[FT]
                        println(io, "        $(cs.tmptype) _tmp;")
                        println(io, "        if (!PyArg_Parse(value, \"$(cs.fmt)\", &_tmp)) return -1;")
                        println(io, "        int32_t _err = 0; char *_errmsg = NULL;")
                        println(io, "        pt_field_set_$(tname)_$(fname)(h, ($(cs.ctype))_tmp, &_err, &_errmsg);")
                    end
                    println(io, "        if (_err) { PyErr_SetString(PyExc_RuntimeError, _errmsg ? _errmsg : \"error setting $fname\"); free(_errmsg); return -1; }")
                    println(io, "        return 0;")
                    println(io, "    }")
                end
                println(io, "    return PyObject_GenericSetAttr(self, name, value);")
                println(io, "}")
            end
        else
            scalar_fields = [(string(fieldname(T, i)), fieldtype(T, i), fieldoffset(T, i))
                             for i in 1:fieldcount(T) if isscalar(fieldtype(T, i))]
            has_getattr = !isempty(scalar_fields)
            if has_getattr
                println(io, "static PyObject *_pt_getattr_$tname(PyObject *self, PyObject *name) {")
                println(io, "    void *_d = ((_PtObj_$tname *)self)->_data;")
                for (fname, ftype, off) in scalar_fields
                    ctype = _c_ctype(ftype)
                    build = _bp_scalar(ftype, "_f", "_v")
                    println(io, "    if (PyUnicode_CompareWithASCIIString(name, \"$fname\") == 0) {")
                    println(io, "        $ctype _f = *($ctype *)((char *)_d + $off);")
                    for s in build; println(io, "        ", s); end
                    println(io, "        return _v;")
                    println(io, "    }")
                end
                println(io, "    return PyObject_GenericGetAttr(self, name);")
                println(io, "}")
            end

            # Mutable setattr: when @pyhandle T mutable=true, generate a setattrofunc
            # that writes each scalar field directly to the heap memory at its offset.
            has_setattr = T in mutable_types
            if has_setattr
                mutable_scalar_fields = [(string(fieldname(T, i)), fieldtype(T, i), fieldoffset(T, i))
                                         for i in 1:fieldcount(T) if isscalar(fieldtype(T, i))]
                println(io, "static int _pt_setattr_$(tname)(PyObject *self, PyObject *name, PyObject *value) {")
                println(io, "    if (value == NULL) {")
                println(io, "        PyErr_SetString(PyExc_TypeError, \"cannot delete $tname attribute\");")
                println(io, "        return -1;")
                println(io, "    }")
                println(io, "    void *_d = ((_PtObj_$(tname) *)self)->_data;")
                for (fname, ftype, off) in mutable_scalar_fields
                    cs = _CSCALARS[ftype]
                    println(io, "    if (PyUnicode_CompareWithASCIIString(name, \"$fname\") == 0) {")
                    println(io, "        $(cs.tmptype) _tmp;")
                    println(io, "        if (!PyArg_Parse(value, \"$(cs.fmt)\", &_tmp)) return -1;")
                    println(io, "        *($(cs.ctype) *)((char *)_d + $off) = ($(cs.ctype))_tmp;")
                    println(io, "        return 0;")
                    println(io, "    }")
                end
                println(io, "    return PyObject_GenericSetAttr(self, name, value);")
                println(io, "}")
            end
        end

        # PyMethodDef table (Py_tp_methods): context managers (__enter__/__exit__) +
        # bound named methods (obj.name(args)).
        enter_m = findfirst(m -> m.dunder === :__enter__, tmeths)
        exit_m  = findfirst(m -> m.dunder === :__exit__,  tmeths)
        tnamed  = filter(m -> m.handle_type === T, named_methods)
        has_tp_methods = !isnothing(enter_m) || !isnothing(exit_m) || !isempty(tnamed)
        if has_tp_methods
            if !isnothing(enter_m)
                println(io, "static PyObject *_pt_meth_$(tname)_enter(PyObject *self, PyObject *_unused) {")
                println(io, "    (void)_unused;")
                println(io, "    Py_INCREF(self);")
                println(io, "    return self;")
                println(io, "}")
            end
            if !isnothing(exit_m)
                exit_sym = cabi_symbol(tmeths[exit_m])
                println(io, "extern int8_t $(exit_sym)(PtHandle, int32_t *, char **);")
                println(io, "static PyObject *_pt_meth_$(tname)_exit(PyObject *self, PyObject *args) {")
                println(io, "    (void)args;")
                println(io, "    _PtObj_$(tname) *obj = (_PtObj_$(tname) *)self;")
                println(io, "    PtHandle h = { obj->_data };")
                println(io, "    int32_t _err = 0; char *_errmsg = NULL;")
                println(io, "    int8_t r = $(exit_sym)(h, &_err, &_errmsg);")
                println(io, "    if (_err) {")
                println(io, "        PyErr_SetString(PyExc_RuntimeError,")
                println(io, "            _errmsg ? _errmsg : \"error in __exit__\");")
                println(io, "        free(_errmsg);")
                println(io, "        return NULL;")
                println(io, "    }")
                println(io, "    return PyBool_FromLong((long)r);")
                println(io, "}")
            end
            for m in tnamed
                _emit_named_method_wrapper(io, tname, m)
            end
            println(io, "static PyMethodDef _pt_methods_$(tname)[] = {")
            !isnothing(enter_m) && println(io,
                "    {\"__enter__\", (PyCFunction)_pt_meth_$(tname)_enter, METH_NOARGS, NULL},")
            !isnothing(exit_m) && println(io,
                "    {\"__exit__\", (PyCFunction)_pt_meth_$(tname)_exit, METH_VARARGS, NULL},")
            for m in tnamed
                println(io, "    {\"$(m.py_name)\", (PyCFunction)_pt_namedwrap_$(tname)_$(m.py_name), METH_VARARGS, NULL},")
            end
            println(io, "    {NULL, NULL, 0, NULL}")
            println(io, "};")
        end

        # Properties: emit getter C functions and a PyGetSetDef table.
        tprops = filter(p -> p.handle_type === T, properties)
        has_getset = !isempty(tprops)
        if has_getset
            for p in tprops
                get_sym = string("pt_prop_get_$(tname)_$(p.prop_name)")
                vc = c_abi_type(p.val_type)
                c_vt = _c_ctype(vc)
                box_stmts = _build_pyobject(vc, "r", "_result")
                println(io, "extern $c_vt $(get_sym)(PtHandle, int32_t *, char **);")
                println(io, "static PyObject *_pt_getter_$(tname)_$(p.prop_name)(PyObject *self, void *closure) {")
                println(io, "    (void)closure;")
                println(io, "    _PtObj_$(tname) *obj = (_PtObj_$(tname) *)self;")
                println(io, "    PtHandle h = { obj->_data };")
                println(io, "    int32_t _err = 0; char *_errmsg = NULL;")
                println(io, "    $c_vt r = $(get_sym)(h, &_err, &_errmsg);")
                println(io, "    if (_err) {")
                println(io, "        PyErr_SetString(PyExc_RuntimeError,")
                println(io, "            _errmsg ? _errmsg : \"error in property $(p.prop_name)\");")
                println(io, "        free(_errmsg);")
                println(io, "        return NULL;")
                println(io, "    }")
                for s in box_stmts; println(io, "    ", s); end
                println(io, "    return _result;")
                println(io, "}")
            end
            println(io, "static PyGetSetDef _pt_getset_$(tname)[] = {")
            for p in tprops
                println(io, "    {\"$(p.prop_name)\", _pt_getter_$(tname)_$(p.prop_name), NULL, \"$(p.prop_name) (property)\", NULL},")
            end
            println(io, "    {NULL, NULL, NULL, NULL, NULL}")
            println(io, "};")
        end

        # tp_new slot: emitted before the slot array (needs the extern declaration).
        if tnew !== nothing
            _emit_tp_new_slot(io, tname, tnew)
        end

        # Slots array: always dealloc + repr (user or default), then all other
        # @pymethod dunders in registration order, then auto field-access getattro.
        println(io, "static PyType_Slot _pt_slots_$tname[] = {")
        println(io, "    {Py_tp_dealloc, (void *)_pt_dealloc_$tname},")
        if tnew !== nothing
            println(io, "    {Py_tp_new,     (void *)_pt_new_$(tname)},")
        end
        if has_repr
            println(io, "    {Py_tp_repr,    (void *)_pt_slot_$(tname)_repr},")
        else
            println(io, "    {Py_tp_repr,    (void *)_pt_repr_$tname},")
        end
        for m in tmeths
            m.dunder === :__repr__ && continue                       # already emitted above
            m.dunder ∈ (:__eq__, :__ne__, :__lt__, :__le__, :__gt__, :__ge__) && continue  # richcmp
            m.dunder ∈ (:__enter__, :__exit__) && continue           # tp_methods
            (is_numeric_binary(m.dunder) || is_numeric_reflected(m.dunder)) && continue  # grouped below
            clean = replace(replace(string(m.dunder), r"^__" => ""), r"__$" => "")
            slot  = _PYMETHOD_SLOTS[m.dunder].slot
            println(io, "    {$slot, (void *)_pt_slot_$(tname)_$(clean)},")
        end
        if has_richcmp
            println(io, "    {Py_tp_richcompare, (void *)_pt_richcmp_$(tname)},")
        end
        for slot in numbin_slots
            nbtag = replace(slot, "Py_" => "")
            println(io, "    {$slot, (void *)_pt_$(nbtag)_$(tname)},")
        end
        if has_getattr
            println(io, "    {Py_tp_getattro, (void *)_pt_getattr_$tname},")
        end
        if has_setattr
            println(io, "    {Py_tp_setattro, (void *)_pt_setattr_$tname},")
        end
        if has_tp_methods
            println(io, "    {Py_tp_methods, (void *)_pt_methods_$tname},")
        end
        if has_getset
            println(io, "    {Py_tp_getset, (void *)_pt_getset_$tname},")
        end
        println(io, "    {0, NULL}")
        println(io, "};")

        println(io, "static PyType_Spec _pt_spec_$tname = {")
        println(io, "    \"$mod_name.$tname\", sizeof(_PtObj_$tname), 0,")
        println(io, "    Py_TPFLAGS_DEFAULT, _pt_slots_$tname")
        println(io, "};")
        println(io, "static PyObject *_pt_make_obj_$tname(PtHandle h) {")
        println(io, "    _PtObj_$tname *obj = (_PtObj_$tname *)")
        println(io, "        PyType_GenericAlloc((PyTypeObject *)_PtType_$tname, 0);")
        println(io, "    if (!obj) { free(h.ptr); return NULL; }")
        println(io, "    obj->_data = h.ptr;")
        println(io, "    return (PyObject *)obj;")
        println(io, "}")
    end
    println(io)
end

# Emit PyInit_<mod> lines that create and register each handle type.
function _emit_handle_type_inits(io::IO, mod_name::AbstractString, handle_types::AbstractVector{<:Type})
    for T in handle_types
        tname = string(T.name.name)
        println(io, "    _PtType_$tname = PyType_FromSpec(&_pt_spec_$tname);")
        println(io, "    if (!_PtType_$tname) { Py_DECREF(m); return NULL; }")
        println(io, "    Py_INCREF(_PtType_$tname);")
        println(io, "    if (PyModule_AddObject(m, \"$tname\", _PtType_$tname) < 0) {")
        println(io, "        Py_DECREF(_PtType_$tname); Py_DECREF(m); return NULL; }")
    end
end

const _WRAP_ARRAY_HELPER = """
/* _PtBuf: a minimal Python object that owns a malloc'd byte buffer and exposes it
   via the buffer protocol.  numpy.frombuffer() accepts any buffer-protocol object,
   so Julia's result buffer can be handed straight to NumPy without an intermediate
   copy.  When the NumPy array (and therefore this object) is GC'd, the destructor
   calls free().  Type is heap-allocated via PyType_FromSpec so it works in both
   the full CPython API and the stable ABI (Py_LIMITED_API).  Initialised by
   PyInit_<mod> via PyType_FromSpec. */
typedef struct { PyObject_HEAD void *data; Py_ssize_t len; } _PtBuf;
static void _ptbuf_dealloc(PyObject *self) {
    free(((_PtBuf *)self)->data);
    PyObject_Free(self);
}
static int _ptbuf_getbuf(PyObject *self_, Py_buffer *v, int flags) {
    _PtBuf *self = (_PtBuf *)self_;
    return PyBuffer_FillInfo(v, self_, self->data, self->len, 0, flags);
}
static PyType_Slot _ptbuf_slots[] = {
    {Py_tp_dealloc, (void *)_ptbuf_dealloc},
    {Py_bf_getbuffer, (void *)_ptbuf_getbuf},
    {0, NULL}
};
static PyType_Spec _ptbuf_spec = {
    "parseltongue._PtBuf", sizeof(_PtBuf), 0, Py_TPFLAGS_DEFAULT, _ptbuf_slots
};
static PyObject *_PtBufType = NULL;
/* Create a _PtBuf that takes ownership of `data` (frees it on alloc failure). */
static PyObject *_pt_make_buf(void *data, Py_ssize_t nbytes) {
    _PtBuf *o = (_PtBuf *)PyType_GenericAlloc((PyTypeObject *)_PtBufType, 0);
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
    /* buf ownership: numpy takes a ref via flat.base on success; on failure buf was
       already DECREF'd by frombuffer, so we must not touch it after this point. */
    Py_DECREF(buf);
    Py_DECREF(np);
    if (!flat) return NULL;
    PyObject *sh = PyTuple_New(ndim);
    if (!sh) { Py_DECREF(flat); return NULL; }
    for (int i = 0; i < ndim; i++) {
        PyObject *_sh_item = PyLong_FromSsize_t(shape[i]);
        if (!_sh_item) { Py_DECREF(sh); Py_DECREF(flat); return NULL; }
        PyTuple_SetItem(sh, i, _sh_item);
    }
    PyObject *kw = Py_BuildValue("{s:s}", "order", order == 1 ? "F" : "C");
    PyObject *args = PyTuple_Pack(1, sh);
    PyObject *reshape = PyObject_GetAttrString(flat, "reshape");
    PyObject *arr = (reshape && args && kw) ? PyObject_Call(reshape, args, kw) : NULL;
    Py_XDECREF(reshape); Py_XDECREF(args); Py_XDECREF(kw); Py_DECREF(sh); Py_DECREF(flat);
    return arr;
}
"""

"""
    emit_cshim(mod_name, exports, errors, handle_types; doc="", abi3=false) -> String

Return the full C source of the CPython extension module `mod_name` exporting
`exports`. Compile + link with the trimmed `img.a` to get an importable extension.

`handle_types` is the list of Julia types registered with `@pyhandle`; each gets
a proper `PyTypeObject` so Python sees `mod.T` as a real class.

When `abi3=true` the shim defines `Py_LIMITED_API 0x030B0000` (Python 3.11 floor —
the version that added `PyObject_GetBuffer` to the stable ABI) and emits only
stable-ABI calls. The resulting `.abi3.so` is compatible with any CPython ≥ 3.11.
"""
function emit_cshim(mod_name::AbstractString, exports::AbstractVector{PtExport},
                    errors::Vector{PtError}=PtError[],
                    handle_types::Vector{<:Type}=Type[],
                    methods::Vector{PtMethod}=PtMethod[],
                    news::Vector{PtNew}=PtNew[];
                    mutable_types::Vector{<:Type}=Type[],
                    mutable_struct_types::Vector{<:Type}=Type[],
                    properties::Vector{PtProperty}=PtProperty[],
                    named_methods::Vector{PtNamedMethod}=PtNamedMethod[],
                    doc::AbstractString="", abi3::Bool=false)
    isempty(doc) && (doc = "ParselTongue extension (Julia via juliac --trim)")
    io = IOBuffer()
    println(io, "/* Generated by ParselTongue — do not edit. */")
    println(io, "#define PY_SSIZE_T_CLEAN")
    # Py_LIMITED_API must be defined before Python.h to restrict to the stable ABI.
    # Floor 0x030B0000 = Python 3.11, the version that added PyObject_GetBuffer to
    # the stable ABI (needed for zero-copy numeric array returns).
    abi3 && println(io, "#define Py_LIMITED_API 0x030B0000")
    println(io, "#include <Python.h>")
    println(io, "#include <stdint.h>")
    println(io, "#include <stdbool.h>")
    println(io, "#include <stdlib.h>")
    println(io, "#include <string.h>")
    println(io)
    eglobals = _error_globals(errors)
    if !isempty(eglobals)
        println(io, "/* Custom Python exception type globals (@pyerror) */")
        for s in eglobals; println(io, s); end
        println(io)
    end
    # All C-ABI carrier typedefs are emitted up front (before the handle-type defs),
    # because @pymethod slot wrappers — generated inside the handle defs — may
    # reference array/opt/dict/tuple carriers (e.g. __getitem__/__next__ returns).
    carriers = _carrier_set(exports, methods, news, properties, named_methods)
    # PtHandle first: tuple carriers may embed it as a field.
    if _uses_handles(exports) || !isempty(handle_types) || !isempty(methods) || !isempty(named_methods)
        print(io, _PTHANDLE_TYPEDEF)
    end
    cstructs = _complex_structs(carriers)
    if !isempty(cstructs)
        println(io, "/* C-ABI carriers for complex numbers (match Julia Complex{T}) */")
        for s in cstructs; println(io, s); end
        println(io)
    end
    if any(_carrier_is_bytes, carriers)
        print(io, _WRAP_BYTES_HELPER)
    end
    if any(_carrier_is_strarr, carriers)
        print(io, _WRAP_STRARR_HELPER)
    end
    structs = _array_structs(carriers)
    if !isempty(structs)
        println(io, "/* C-ABI carriers for N-D arrays (match Julia PtArray{T,N}) */")
        for s in structs; println(io, s); end
        println(io)
        println(io, _WRAP_ARRAY_HELPER)
    end
    ostructs = _opt_structs(carriers)
    if !isempty(ostructs)
        println(io, "/* C-ABI carriers for Optional types (match Julia Union{T,Nothing}) */")
        for s in ostructs; println(io, s); end
        println(io)
    end
    dstructs = _dict_structs(carriers)
    if !isempty(dstructs)
        println(io, "/* C-ABI carriers for Dict{String,V} types */")
        for s in dstructs; println(io, s); end
        println(io)
    end
    tstructs = _tuple_structs(carriers)
    if !isempty(tstructs)
        println(io, "/* C-ABI carriers for tuple returns (match Julia Tuple{...}) */")
        for s in tstructs; println(io, s); end
        println(io)
    end
    _emit_handle_type_defs(io, mod_name, handle_types, methods, news;
                           mutable_types, mutable_struct_types, properties, named_methods)
    println(io, "/* C-ABI entry points emitted by juliac --trim */")
    for e in exports
        println(io, _extern_decl(e))
    end
    println(io)
    wnames = String[]
    for e in exports
        fn, wname = _wrapper_fn(e; errors, abi3)
        println(io, fn); println(io)
        push!(wnames, wname)
    end
    println(io, "static PyMethodDef ", mod_name, "_methods[] = {")
    for (e, wname) in zip(exports, wnames)
        has_va = any(a -> isvarargs(a.jl_type), e.args)
        has_kw = any(a -> a.default !== nothing || a.is_keyword, e.args)
        # export_name is validated as a Python identifier by _is_py_ident, so it
        # is always safe to embed in a C string literal (no " or \ possible).
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
    println(io, "    PyModuleDef_HEAD_INIT, \"", mod_name, "\", \"", _c_escape(doc), "\", -1, ", mod_name, "_methods")
    println(io, "};")
    println(io)
    println(io, "PyMODINIT_FUNC PyInit_", mod_name, "(void) {")
    if _uses_arrays(carriers)
        # PyType_FromSpec heap-allocates the type; works in both full and stable ABI.
        println(io, "    _PtBufType = PyType_FromSpec(&_ptbuf_spec);")
        println(io, "    if (!_PtBufType) return NULL;")
    end
    println(io, "    /* trimmed Julia lib self-initializes on first @ccallable call */")
    if isempty(errors) && isempty(handle_types)
        println(io, "    return PyModule_Create(&", mod_name, "_module);")
    else
        println(io, "    PyObject *m = PyModule_Create(&", mod_name, "_module);")
        println(io, "    if (!m) return NULL;")
        _emit_handle_type_inits(io, mod_name, handle_types)
        for s in _error_inits(mod_name, errors)
            println(io, "    ", s)
        end
        println(io, "    return m;")
    end
    println(io, "}")
    return String(take!(io))
end
