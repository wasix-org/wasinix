// Best-effort implementations for POSIX functions wasix-libc declares (in
// sys/mman.h, sched.h, unistd.h) but builds no backend for, so a reference
// becomes an undefined dynamic import that traps under wasmer. wasm has no
// memory locking, no per-CPU scheduling, and no thread niceness; these let
// consumers (duckdb, opencv, zeromq) link and run.
//
// Copied into libc-bottom-half/sources/ by pkgs/toolchain/sysroot/libc.nix,
// where the Makefile globs *.c. The signatures use plain types (not cpu_set_t,
// which is behind a feature macro the libc's own build doesn't set) and bind by
// symbol name; consumers still call through the real header declarations. See
// WASIX-TODO.md.
#include <stddef.h>
#include <string.h>
#include <unistd.h>

// Memory locking is a no-op: the whole linear memory is always resident.
int mlock(const void *addr, size_t len) {
  (void)addr;
  (void)len;
  return 0;
}
int munlock(const void *addr, size_t len) {
  (void)addr;
  (void)len;
  return 0;
}
// Advice is a hint; ignoring it is always correct.
int madvise(void *addr, size_t len, int advice) {
  (void)addr;
  (void)len;
  (void)advice;
  return 0;
}

// No per-CPU scheduling on wasm: always report CPU 0.
int sched_getcpu(void) { return 0; }

// No thread-priority niceness on wasm; report success without changing anything
// (declaration unhidden by wasix-libc-sched.patch). Lets libzmq's
// applySchedulingParameters link once _POSIX_THREAD_PRIORITY_SCHEDULING is set.
int nice(int inc) {
  (void)inc;
  return 0;
}

// A cpu_set_t is an array of unsigned long (a bitset); take it as raw memory.
// Report the runtime's thread parallelism (sysconf reads
// __wasi_thread_parallelism) as the affinity mask, so CPU-count probes see the
// real value instead of trapping.
int sched_getaffinity(int pid, size_t cpusetsize, void *mask) {
  (void)pid;
  if (!mask || cpusetsize == 0)
    return 0;
  memset(mask, 0, cpusetsize);
  long n = sysconf(_SC_NPROCESSORS_ONLN);
  if (n < 1)
    n = 1;
  unsigned long *bits = (unsigned long *)mask;
  size_t nbits = cpusetsize * 8;
  for (long i = 0; i < n && (size_t)i < nbits; i++)
    bits[i / (8 * sizeof(long))] |= (1UL << (i % (8 * sizeof(long))));
  return 0;
}

// CPU_COUNT() lowers to __sched_cpucount (musl's sched_cpucount.c isn't in the
// wasix-libc build, so the reference is an undefined dynamic import). Count the
// set bits in the mask, taken as raw memory like sched_getaffinity above, so
// opencv's cv::getNumberOfCPUs() resolves and returns the affinity size.
int __sched_cpucount(size_t setsize, const void *set) {
  if (!set || setsize == 0)
    return 0;
  const unsigned char *p = (const unsigned char *)set;
  int cnt = 0;
  for (size_t i = 0; i < setsize; i++)
    for (int j = 0; j < 8; j++)
      if (p[i] & (1u << j))
        cnt++;
  return cnt;
}
