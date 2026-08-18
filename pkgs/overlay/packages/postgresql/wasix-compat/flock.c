/*
 * libuuid locks its clock-state file with flock, which is declared in
 * <sys/file.h> but absent from libc.a. A single-process wasm guest needs no
 * lock, so succeed.
 */
#include <sys/file.h>

int flock(int fd, int operation) {
  (void)fd;
  (void)operation;
  return 0;
}
