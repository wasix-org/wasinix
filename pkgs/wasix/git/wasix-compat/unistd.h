#ifndef _WASIX_COMPAT_UNISTD_H
#define _WASIX_COMPAT_UNISTD_H
#include_next <unistd.h>
/* fork() is hidden when __wasm_exception_handling__ is defined. */
#ifndef __WASIX_FORK_DECLARED
#define __WASIX_FORK_DECLARED
pid_t fork(void);
#endif
#endif
