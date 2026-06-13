#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

extern int64_t pt_err_static(int64_t a, int64_t b, int32_t *pt_err, char **pt_errmsg);
extern int64_t pt_err_msg(int64_t a, int64_t b, int32_t *pt_err, char **pt_errmsg);

static int check(const char *name, int64_t a, int64_t b,
                 int64_t (*fn)(int64_t, int64_t, int32_t *, char **),
                 int expect_err, int64_t expect_val, const char *expect_msg) {
    int32_t err = 0;
    char *msg = NULL;
    int64_t r = fn(a, b, &err, &msg);
    if (expect_err) {
        if (!err) { printf("FAIL %s: expected error, got %lld\n", name, (long long)r); return 1; }
        if (expect_msg && (!msg || !strstr(msg, expect_msg))) {
            printf("FAIL %s: expected msg containing '%s', got '%s'\n", name, expect_msg, msg ? msg : "(null)");
            free(msg); return 1;
        }
        printf("PASS %s: got error '%s'\n", name, msg ? msg : "(null)");
        free(msg);
    } else {
        if (err) { printf("FAIL %s: unexpected error '%s'\n", name, msg ? msg : "(null)"); free(msg); return 1; }
        if (r != expect_val) { printf("FAIL %s: expected %lld, got %lld\n", name, (long long)expect_val, (long long)r); return 1; }
        printf("PASS %s: result = %lld\n", name, (long long)r);
    }
    return 0;
}

int main(void) {
    int fail = 0;
    fail += check("static/ok",    2, 3, pt_err_static, 0, 5,  NULL);
    fail += check("static/err",  -1, 3, pt_err_static, 1, 0,  NULL);
    fail += check("msg/ok",       2, 3, pt_err_msg,    0, 5,  NULL);
    fail += check("msg/err",     -1, 3, pt_err_msg,    1, 0,  "negative");
    return fail;
}
