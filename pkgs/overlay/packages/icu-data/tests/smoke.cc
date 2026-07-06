// Formats the epoch as a German long date via ICU's C API. Needs the icu
// locale data archive at the compiled-in default path (no ICU_DATA set):
// without it u_init/udat fail and this exits nonzero.
#include <stdio.h>
#include <unicode/uclean.h>
#include <unicode/udat.h>
#include <unicode/ustring.h>
#include <unicode/utypes.h>

int main(void) {
  UErrorCode status = U_ZERO_ERROR;
  u_init(&status);
  if (U_FAILURE(status)) {
    printf("u_init failed: %s\n", u_errorName(status));
    return 1;
  }
  UChar gmt[] = {'G', 'M', 'T', 0};
  UDateFormat *df =
      udat_open(UDAT_NONE, UDAT_LONG, "de_DE", gmt, -1, NULL, 0, &status);
  if (U_FAILURE(status)) {
    printf("udat_open failed: %s\n", u_errorName(status));
    return 1;
  }
  UChar ubuf[64];
  int32_t len = udat_format(df, 0.0, ubuf, 64, NULL, &status);
  if (U_FAILURE(status) || len <= 0 || len >= 64) {
    printf("udat_format failed: %s\n", u_errorName(status));
    return 1;
  }
  char buf[256];
  u_austrncpy(buf, ubuf, len);
  buf[len] = 0;
  printf("%s\n", buf);
  udat_close(df);
  u_cleanup();
  return 0;
}
