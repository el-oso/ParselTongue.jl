#include <stdio.h>
#include <stdint.h>
typedef struct { double f1; int64_t f2; } Pair_d_i;
typedef struct { double* data; int64_t shape[1]; int32_t order; } PtArray_f64_1;
typedef struct { double f1; PtArray_f64_1 f2; } ArrPair;
extern Pair_d_i pt_pair(void);
extern ArrPair  pt_arrpair(void);
int main(void){
    int ok=1;
    Pair_d_i p = pt_pair();
    printf("pt_pair = (%g, %lld)\n", p.f1, (long long)p.f2);
    ok &= (p.f1==1.5 && p.f2==7);
    ArrPair a = pt_arrpair();
    printf("pt_arrpair = (%g, [%g,%g,%g] len=%lld order=%d)\n",
           a.f1, a.f2.data[0], a.f2.data[1], a.f2.data[2], (long long)a.f2.shape[0], a.f2.order);
    ok &= (a.f1==99.0 && a.f2.data[0]==10.0 && a.f2.data[2]==30.0 && a.f2.shape[0]==3);
    printf(ok?"TUPLE ABI OK\n":"TUPLE ABI FAIL\n");
    return ok?0:1;
}
