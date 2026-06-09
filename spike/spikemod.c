#define PY_SSIZE_T_CLEAN
#include <Python.h>
#include <stdint.h>

/* C-ABI entrypoint emitted by juliac --trim from add.jl (Base.@ccallable pt_add) */
extern int64_t pt_add(int64_t a, int64_t b);

static PyObject *py_add(PyObject *self, PyObject *args) {
    long long a, b;
    if (!PyArg_ParseTuple(args, "LL", &a, &b))
        return NULL;
    int64_t r = pt_add((int64_t)a, (int64_t)b);
    return PyLong_FromLongLong((long long)r);
}

static PyMethodDef SpikeMethods[] = {
    {"add", py_add, METH_VARARGS, "add(a, b) -> a + b, computed in Julia"},
    {NULL, NULL, 0, NULL},
};

static struct PyModuleDef spikemodule = {
    PyModuleDef_HEAD_INIT,
    "spikemod",
    "ParselTongue spike: a Julia-backed CPython extension",
    -1,
    SpikeMethods,
};

PyMODINIT_FUNC PyInit_spikemod(void) {
    /* The trimmed Julia library self-initializes on first @ccallable call,
       so no explicit jl_init() is required here (confirmed via ctest). */
    return PyModule_Create(&spikemodule);
}
