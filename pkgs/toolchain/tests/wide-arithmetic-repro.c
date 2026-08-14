#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>

__attribute__((noinline)) static int64_t checked_mul(int64_t a, int64_t b,
                                                     char *overflow) {
  int64_t result;

  if (__builtin_mul_overflow(a, b, &result)) {
    *overflow = 1;
  }
  return result;
}

static int check(int64_t a, int64_t b, int expect_overflow) {
  char overflow = 0;
  int64_t result = checked_mul(a, b, &overflow);

  if (overflow != expect_overflow) {
    fprintf(stderr,
            "overflow was %d, expected %d for %" PRId64 " * %" PRId64
            "; returned %" PRId64 "\n",
            overflow, expect_overflow, a, b, result);
    return 1;
  }
  return 0;
}

int main(void) {
  int failed = 0;

  failed |= check(3, 7, 0);
  failed |= check(6, 2, 0);
  failed |= check(INT64_MIN, INT64_MIN, 1);
  failed |= check(INT64_MAX, INT64_MAX, 1);
  return failed;
}
