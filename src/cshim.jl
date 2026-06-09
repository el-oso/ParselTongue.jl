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
)

isarray(@nospecialize(C::Type)) = C isa DataType && C.name === PtBuffer.body.name
_elt(@nospecialize(C::Type)) = _ELTINFO[C.parameters[1]]
_structname(@nospecialize(C::Type)) = string("PtBuffer_", _elt(C).tag)

# ── Per-carrier C type / arg / return ─────────────────────────────────

function _c_ctype(@nospecialize(C::Type))
    isscalar(C) && return _CSCALARS[C].ctype
    C === Cstring && return "char *"
    isarray(C) && return _structname(C)
    error("ParselTongue: no C type for carrier `$C`.")
end

function _arg_plan(@nospecialize(C::Type), i::Int)
    tmp = string("a", i)
    if isscalar(C)
        cs = _CSCALARS[C]
        return ArgPlan([string(cs.tmptype, " ", tmp, ";")], cs.fmt, [string("&", tmp)],
                       string("(", cs.ctype, ")", tmp))
    elseif C === Cstring
        return ArgPlan([string("const char *", tmp, ";")], "s", [string("&", tmp)],
                       string("(char *)", tmp))
    elseif isarray(C)
        e = _elt(C); sn = _structname(C); obj = string(tmp, "_obj"); buf = string(tmp, "_buf")
        decls = [string("PyObject *", obj, ";"), string("Py_buffer ", buf, ";"),
                 string(sn, " ", tmp, ";")]
        setup = [
            string("if (PyObject_GetBuffer(", obj, ", &", buf, ", PyBUF_CONTIG_RO) != 0) return NULL;"),
            string("if (", buf, ".itemsize != (Py_ssize_t)sizeof(", e.ctype, ") || ", buf, ".ndim > 1) {"),
            string("    PyBuffer_Release(&", buf, ");"),
            string("    PyErr_SetString(PyExc_TypeError, \"expected a 1-D ", e.np, " buffer\"); return NULL;"),
            "}",
            string(tmp, ".data = (", e.ctype, " *)", buf, ".buf;"),
            string(tmp, ".len = (int64_t)(", buf, ".len / (Py_ssize_t)sizeof(", e.ctype, "));"),
        ]
        return ArgPlan(decls, "O", [string("&", obj)], setup, tmp,
                       [string("PyBuffer_Release(&", buf, ");")])
    end
    error("ParselTongue: no argument marshalling for carrier `$C`.")
end

function _ret_plan(@nospecialize(C::Type))
    if isscalar(C)
        cs = _CSCALARS[C]
        return RetPlan([string("return ", cs.build, "((", cs.cast, ")r);")])
    elseif C === Cstring
        return RetPlan(["PyObject *o = PyUnicode_FromString(r);", "free((void *)r);", "return o;"])
    elseif isarray(C)
        e = _elt(C)
        return RetPlan([
            string("Py_ssize_t nbytes = (Py_ssize_t)r.len * (Py_ssize_t)sizeof(", e.ctype, ");"),
            "PyObject *ba = PyByteArray_FromStringAndSize((const char *)r.data, nbytes);",
            "free(r.data);",
            "if (!ba) return NULL;",
            string("PyObject *out = _pt_wrap_array(ba, \"", e.np, "\");"),
            "Py_DECREF(ba);",
            "return out;",
        ])
    end
    error("ParselTongue: no return marshalling for carrier `$C`.")
end

# ── Codegen ───────────────────────────────────────────────────────────

function _extern_decl(e::PtExport)
    ret = _c_ctype(c_abi_type(e.ret))
    args = isempty(e.args) ? "void" :
           join((_c_ctype(c_abi_type(a.jl_type)) for a in e.args), ", ")
    string("extern ", ret, " ", cabi_symbol(e), "(", args, ");")
end

function _wrapper_fn(e::PtExport)
    wname = string("pyw_", e.export_name)
    io = IOBuffer()
    println(io, "static PyObject *", wname, "(PyObject *self, PyObject *args) {")

    fmt = IOBuffer()
    addrs = String[]; callargs = String[]; setups = String[]; cleanups = String[]
    for (i, a) in enumerate(e.args)
        plan = _arg_plan(c_abi_type(a.jl_type), i)
        for d in plan.decls; println(io, "    ", d); end
        print(fmt, plan.fmt)
        append!(addrs, plan.addrs); append!(setups, plan.setup); append!(cleanups, plan.cleanup)
        push!(callargs, plan.callarg)
    end

    if isempty(e.args)
        println(io, "    if (!PyArg_ParseTuple(args, \"\")) return NULL;")
    else
        println(io, "    if (!PyArg_ParseTuple(args, \"", String(take!(fmt)), "\", ",
                join(addrs, ", "), ")) return NULL;")
    end
    for s in setups; println(io, "    ", s); end

    retc = c_abi_type(e.ret)
    println(io, "    ", _c_ctype(retc), " r = ", cabi_symbol(e), "(", join(callargs, ", "), ");")
    for s in cleanups; println(io, "    ", s); end
    for s in _ret_plan(retc).stmts; println(io, "    ", s); end
    println(io, "}")
    return String(take!(io)), wname
end

# C struct typedefs for every PtBuffer{T} carrier appearing in `exports`.
function _array_structs(exports::AbstractVector{PtExport})
    seen = Set{Type}()
    out = String[]
    for e in exports
        for C in (c_abi_type(e.ret), (c_abi_type(a.jl_type) for a in e.args)...)
            if isarray(C) && !(C in seen)
                push!(seen, C)
                ei = _elt(C)
                push!(out, string("typedef struct { ", ei.ctype, " *data; int64_t len; } ",
                                  _structname(C), ";"))
            end
        end
    end
    out
end

_uses_arrays(exports) = !isempty(_array_structs(exports))

const _WRAP_ARRAY_HELPER = """
/* Turn a bytearray of raw elements into a numpy array if numpy is importable,
   else a memoryview. The result keeps a reference to `ba`, so the caller may
   DECREF it afterwards. numpy is resolved at runtime — never a build dependency. */
static PyObject *_pt_wrap_array(PyObject *ba, const char *dtype) {
    PyObject *np = PyImport_ImportModule("numpy");
    if (np) {
        PyObject *arr = PyObject_CallMethod(np, "frombuffer", "Os", ba, dtype);
        Py_DECREF(np);
        return arr;
    }
    PyErr_Clear();
    return PyMemoryView_FromObject(ba);
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
    structs = _array_structs(exports)
    if !isempty(structs)
        println(io, "/* C-ABI carriers for 1-D numeric arrays (match Julia PtBuffer{T}) */")
        for s in structs; println(io, s); end
        println(io)
        println(io, _WRAP_ARRAY_HELPER)
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
        println(io, "    {\"", e.export_name, "\", ", wname, ", METH_VARARGS, \"",
                e.export_name, " (Julia)\"},")
    end
    println(io, "    {NULL, NULL, 0, NULL}")
    println(io, "};")
    println(io)
    println(io, "static struct PyModuleDef ", mod_name, "_module = {")
    println(io, "    PyModuleDef_HEAD_INIT, \"", mod_name, "\", \"", doc, "\", -1, ", mod_name, "_methods")
    println(io, "};")
    println(io)
    println(io, "PyMODINIT_FUNC PyInit_", mod_name, "(void) {")
    println(io, "    /* trimmed Julia lib self-initializes on first @ccallable call */")
    println(io, "    return PyModule_Create(&", mod_name, "_module);")
    println(io, "}")
    return String(take!(io))
end
