/* ASan/LSan gate for the generated C glue (item: harden the C glue).
 *
 * The generated shim marshals Python <-> C-ABI carriers and calls the Julia
 * `pt_*` entry points. Those marshalling paths had memory bugs (missing free on
 * error paths, refcount slips: A1, A2, A6, A15). ASan-ing the *real* extension is
 * noisy because it embeds the Julia runtime, so this driver tests the glue in
 * isolation: it #includes the generated shim and provides STUB `pt_*` symbols that
 * allocate carriers exactly as Julia would (strdup'd dict keys, malloc'd Cstrings
 * and arrays). Each wrapped function is then called through the real CPython
 * dispatch path and a scoped LSan check flags any leak the glue introduced.
 *
 * Build (see test/asan/run.sh / the CI step):
 *   julia --project=. test/asan/gen_shim.jl > shim_generated.c
 *   cc -fsanitize=address -fno-omit-frame-pointer -g -I. shim_generated.c \
 *      $(python3-config --includes --ldflags --embed) -o asan_glue
 *   PYTHONMALLOC=malloc ASAN_OPTIONS=detect_leaks=1 ./asan_glue
 */
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdio.h>

/* Pull in Python.h, the carrier typedefs, the static wrappers, and
 * PyInit_asan_carriers — all generated. Stubs below use these typedefs. */
#include "shim_generated.c"

/* On-demand leak check (provided by the ASan/LSan runtime). Returns nonzero and
 * prints a report if any unreachable allocation exists at the call site. */
int __lsan_do_recoverable_leak_check(void);

/* ── Stub pt_* entry points ──────────────────────────────────────────────
 * Each mimics the trimmed Julia @ccallable: set *err/*errmsg, return a carrier
 * heap-allocated the way Julia's to_c would (so the shim's free() calls match). */

PtDict_double pt_d(int32_t *err, char **errmsg) {
    *err = 0; *errmsg = NULL;
    PtDict_double r;
    r.len = 3;
    r.keys = (char **)malloc((size_t)r.len * sizeof(char *));
    r.vals = (double *)malloc((size_t)r.len * sizeof(double));
    const char *names[3] = {"a", "b", "c"};
    for (int64_t i = 0; i < r.len; i++) { r.keys[i] = strdup(names[i]); r.vals[i] = (double)i; }
    return r;
}

PtOpt_str pt_opt_some(int32_t *err, char **errmsg) {
    *err = 0; *errmsg = NULL;
    PtOpt_str r; r.has_value = 1; r.value = strdup("hello"); return r;
}

PtOpt_str pt_opt_none(int32_t *err, char **errmsg) {
    *err = 0; *errmsg = NULL;
    PtOpt_str r; r.has_value = 0; r.value = NULL; return r;
}

PtStrArray pt_strs(int32_t *err, char **errmsg) {
    *err = 0; *errmsg = NULL;
    PtStrArray r; r.len = 3;
    r.data = (char **)malloc((size_t)r.len * sizeof(char *));
    const char *vals[3] = {"x", "y", "z"};
    for (int64_t i = 0; i < r.len; i++) r.data[i] = strdup(vals[i]);
    return r;
}

PtArray_u8t_1 pt_bytes_(int32_t *err, char **errmsg) {
    *err = 0; *errmsg = NULL;
    PtArray_u8t_1 r; r.shape[0] = 4; r.order = 0;
    r.data = (uint8_t *)malloc((size_t)r.shape[0]);
    for (int i = 0; i < 4; i++) r.data[i] = (uint8_t)(i + 1);
    return r;
}

char *pt_s(int32_t *err, char **errmsg) {
    *err = 0; *errmsg = NULL;
    return strdup("result");
}

PtTuple_double_int64t pt_tup(int32_t *err, char **errmsg) {
    *err = 0; *errmsg = NULL;
    PtTuple_double_int64t r; r.f1 = 1.5; r.f2 = 7; return r;
}

int64_t pt_boom(int32_t *err, char **errmsg) {
    /* Error path: the wrapper must raise and free(*errmsg). */
    *err = 1; *errmsg = strdup("boom");
    return 0;
}

/* Dict *argument* stub: mimics Julia's from_c taking ownership of the carrier —
 * frees each key, the keys array, and vals. The wrapper's post-call disarm must
 * have NULLed the carrier so its __cleanup__ guard does NOT double-free here. */
double pt_take(PtDict_double d, int32_t *err, char **errmsg) {
    *err = 0; *errmsg = NULL;
    double s = 0.0;
    for (int64_t i = 0; i < d.len; i++) { s += d.vals[i]; free(d.keys[i]); }
    free(d.keys); free(d.vals);
    return s;
}

/* ── Harness ─────────────────────────────────────────────────────────── */

static int g_failures = 0;

/* Call `name` once through the module, release the result, GC, then scoped leak
 * check. `expect_err` = the function raises (boom) instead of returning a value. */
static void check_fn(PyObject *mod, const char *name, int expect_err) {
    PyObject *f = PyObject_GetAttrString(mod, name);
    if (!f) { fprintf(stderr, "FAIL: no attribute %s\n", name); g_failures++; return; }
    PyObject *r = PyObject_CallObject(f, NULL);
    if (expect_err) {
        if (r != NULL || !PyErr_Occurred()) {
            fprintf(stderr, "FAIL: %s should have raised\n", name); g_failures++;
        }
        PyErr_Clear();
    } else if (r == NULL) {
        fprintf(stderr, "FAIL: %s raised unexpectedly\n", name);
        PyErr_Print(); g_failures++;
    }
    Py_XDECREF(r);
    Py_DECREF(f);
    PyGC_Collect();
    if (__lsan_do_recoverable_leak_check()) {
        fprintf(stderr, "LEAK detected after %s()\n", name);
        g_failures++;
    }
}

int main(void) {
    Py_Initialize();
    PyObject *mod = PyInit_asan_carriers();
    if (!mod) { fprintf(stderr, "FAIL: PyInit_asan_carriers returned NULL\n"); PyErr_Print(); return 2; }

    const char *names[] = {"d", "opt_some", "opt_none", "strs", "bytes_", "s", "tup", "boom"};
    const int   errs[]  = { 0,   0,          0,          0,      0,        0,   0,     1};

    /* Warm-up pass: absorb one-time reachable caches (interned strings, etc.) so
     * the measured checks below only see genuine glue leaks. A real per-call leak
     * still leaks here AND is reported in the measured pass (recoverable check
     * reports all unreachable blocks), so warm-up cannot hide a true leak. */
    for (size_t i = 0; i < sizeof(names) / sizeof(*names); i++) {
        PyObject *f = PyObject_GetAttrString(mod, names[i]);
        PyObject *r = f ? PyObject_CallObject(f, NULL) : NULL;
        PyErr_Clear(); Py_XDECREF(r); Py_XDECREF(f);
    }
    PyGC_Collect();
    __lsan_do_recoverable_leak_check();   /* baseline; result ignored */

    for (size_t i = 0; i < sizeof(names) / sizeof(*names); i++)
        check_fn(mod, names[i], errs[i]);

    /* ── Dict argument path: scope-guard + disarm (the POC under test) ─────
     * take({...}) success: pt_take frees the carrier; the wrapper's disarm must
     *   prevent the __cleanup__ guard from double-freeing (ASan catches that).
     * take(123) and take({"a": "bad"}) error: the guard must free the (possibly
     *   partial) carrier on the error return (LSan catches a leak). */
    PyObject *take = PyObject_GetAttrString(mod, "take");
    if (!take) { fprintf(stderr, "FAIL: no attribute take\n"); g_failures++; }
    else {
        /* warm-up to absorb one-time caches, then measured calls */
        for (int w = 0; w < 2; w++) {
            PyObject *good = Py_BuildValue("({s:d,s:d,s:d})", "a", 1.0, "b", 2.0, "c", 3.0);
            PyObject *r = PyObject_CallObject(take, good);
            Py_XDECREF(r); Py_DECREF(good); PyErr_Clear();
        }
        PyGC_Collect(); __lsan_do_recoverable_leak_check();  /* baseline */

        /* success path */
        PyObject *good = Py_BuildValue("({s:d,s:d,s:d})", "a", 1.0, "b", 2.0, "c", 3.0);
        PyObject *r = PyObject_CallObject(take, good);
        if (!r) { fprintf(stderr, "FAIL: take(good) raised\n"); PyErr_Print(); g_failures++; }
        Py_XDECREF(r); Py_DECREF(good);
        PyGC_Collect();
        if (__lsan_do_recoverable_leak_check()) { fprintf(stderr, "LEAK after take(good)\n"); g_failures++; }

        /* error path A: not a dict → TypeError before the carrier is built */
        PyObject *bad1 = Py_BuildValue("(i)", 123);
        r = PyObject_CallObject(take, bad1);
        if (r) { fprintf(stderr, "FAIL: take(123) did not raise\n"); g_failures++; }
        Py_XDECREF(r); Py_DECREF(bad1); PyErr_Clear();
        PyGC_Collect();
        if (__lsan_do_recoverable_leak_check()) { fprintf(stderr, "LEAK after take(123)\n"); g_failures++; }

        /* error path B: bad value → PyFloat_AsDouble fails mid-build → guard frees
         * the partially-built carrier (keys[0..i], keys, vals) */
        PyObject *bad2 = Py_BuildValue("({s:d,s:s})", "a", 1.0, "b", "oops");
        r = PyObject_CallObject(take, bad2);
        if (r) { fprintf(stderr, "FAIL: take({bad value}) did not raise\n"); g_failures++; }
        Py_XDECREF(r); Py_DECREF(bad2); PyErr_Clear();
        PyGC_Collect();
        if (__lsan_do_recoverable_leak_check()) { fprintf(stderr, "LEAK after take({bad})\n"); g_failures++; }

        Py_DECREF(take);
    }

    if (g_failures == 0) fprintf(stderr, "ASAN_GLUE_OK\n");
    /* _exit skips the at-exit LSan sweep (which would flag benign, still-reachable
     * CPython interpreter state); the scoped checks above are the gate. */
    fflush(stderr); fflush(stdout);
    _exit(g_failures == 0 ? 0 : 1);
}
