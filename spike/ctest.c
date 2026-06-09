#include <stdio.h>
#include <stdint.h>
extern int64_t pt_add(int64_t, int64_t);
int main(void){
    int64_t r = pt_add(40, 2);
    printf("pt_add(40,2) = %lld\n", (long long)r);
    return r == 42 ? 0 : 1;
}
