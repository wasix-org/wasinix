/* Exercises the whole wasix LAPACK/BLAS stack end to end: the CBLAS C
 * interface, a Fortran LAPACK routine called directly, and (implicitly) the
 * flang runtime pulled in by the pkg-config Libs. A correct result proves
 * flang's wasm32 codegen, the flang-rt link, and the calling ABI all line up.
 */
#include <cblas.h>
#include <stdio.h>

/* Fortran LAPACK, column-major, trailing-underscore mangling. */
extern void dgesv_(const int *n, const int *nrhs, double *a, const int *lda,
                   int *ipiv, double *b, const int *ldb, int *info);

int main(void) {
  /* BLAS via CBLAS: [1,2,3].[4,5,6] = 32 */
  double x[3] = {1.0, 2.0, 3.0};
  double y[3] = {4.0, 5.0, 6.0};
  double dot = cblas_ddot(3, x, 1, y, 1);

  /* LAPACK: solve A*X=B, A=diag(2,4) (column-major), B=[2,8] -> X=[1,2] */
  int n = 2, nrhs = 1, lda = 2, ldb = 2, info = 0;
  int ipiv[2];
  double A[4] = {2.0, 0.0, 0.0, 4.0};
  double B[2] = {2.0, 8.0};
  dgesv_(&n, &nrhs, A, &lda, ipiv, B, &ldb, &info);

  printf("ddot=%.1f solve=%.1f,%.1f info=%d\n", dot, B[0], B[1], info);
  return 0;
}
