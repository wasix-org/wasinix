/* WASIX process-primitive shims for functions absent from sysroot libc.a. */
#include <wasi/api.h>
typedef int pid_t;
extern int errno;

pid_t fork(void) {
  __wasi_pid_t pid;
  __wasi_errno_t err = __wasi_proc_fork((__wasi_bool_t)1, &pid);
  if (err != __WASI_ERRNO_SUCCESS) {
    errno = err;
    return -1;
  }
  return (pid_t)pid;
}

pid_t setsid(void) {
  __wasi_pid_t pid;
  __wasi_proc_id(&pid);
  return (pid_t)pid;
}
