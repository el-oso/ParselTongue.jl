#include <stdio.h>
#include <stdint.h>
#include <math.h>

/* Must match Julia ComplexF64 (immutable {Float64 re; Float64 im;}) */
typedef struct { double re, im; } cf64;

/* Must match Julia PtArray{Float64,2}: data ptr, inline shape[2], Cint order */
typedef struct { double *data; int64_t shape[2]; int32_t order; } PtArray_f64_2;

extern cf64    pt_conj(cf64 z);
extern double  pt_arr_sum(PtArray_f64_2 a);
extern int64_t pt_arr_ndims(PtArray_f64_2 a);

int main(void) {
    int ok = 1;

    cf64 z = {3.0, 4.0};
    cf64 c = pt_conj(z);
    printf("pt_conj(3+4i) = %g%+gi (want 3-4i)\n", c.re, c.im);
    ok &= (c.re == 3.0 && c.im == -4.0);

    /* row-major 2x3: [[1,2,3],[4,5,6]] -> sum 21 */
    double buf[6] = {1,2,3,4,5,6};
    PtArray_f64_2 a = { buf, {2, 3}, 0 };
    double s = pt_arr_sum(a);
    printf("pt_arr_sum(2x3) = %g (want 21)\n", s);
    ok &= (s == 21.0);

    int64_t n = pt_arr_ndims(a);   /* 2*3 + order(0) = 6 */
    printf("pt_arr_ndims = %lld (want 6)\n", (long long)n);
    ok &= (n == 6);

    printf(ok ? "STRUCT ABI OK\n" : "STRUCT ABI FAIL\n");
    return ok ? 0 : 1;
}
