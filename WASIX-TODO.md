# WASIX quirks & issues

Runtime, libc, and toolchain issues hit while packaging: a reference when a
package breaks in a familiar way, and a worklist for upstream fixes. Re-verified
2026-07-02 against wasmer 7.2.0, wasix-libc v2026-06-25.1, binaryen 129; entries
marked "not re-verified" are carried on trust.

Status: 🔴 needs upstream fix · 🟡 workaround in place · 🟢 fixed.

## What belongs here

A reproducible defect in the runtime, libc, or toolchain that a packager can hit
again. Not a passing observation, not a package's own bug, and not a "recheck
this next bump" note (that is `passthru.wasinix.update.notes`,
`docs/updating.md`).

An entry is `### <short symptom> <status>` plus these bullets, in order:

- **Symptom**: what the packager actually sees. The error text, exit code, or
  wrong output, so the entry is greppable from a build log.
- **Consequence**: what it breaks, and how widely.
- **Workaround**: what we do instead, naming the file that does it. Required for
  🟡, omitted otherwise.
- **Fix**: the upstream change that would remove the entry, specific enough to
  act on. Required for 🔴 and 🟡.

Say which version an entry was last checked against when you touch it. Entries
predating this format are being triaged onto it, so verify one against the
current toolchain before relying on it.

## Runtime / libc

### `fchdir` doesn't exist 🟡

- wasix-libc has no `fchdir` at all: not declared in the headers, no symbol in
  `libc.a` (verified: undeclared-function error, then undefined symbol with a
  manual declaration). There is also no general fd-to-path mechanism (only
  preopen names via `fd_prestat_dir_name`).
- Consequence: gnulib's `save_cwd` (open "." + fchdir to restore) can't work;
  its fallback made every gnulib CLI exit non-zero with ENOTDIR.
- Workaround: `find/package.nix` patches `gl/lib/save-cwd.c` to force getcwd +
  chdir.
- Fix: `__wasi_fchdir` in wasmer plus libc wiring. Fixes gnulib CLIs globally.

### `posix_spawn` fd passing 🟡

- Non-stdio fds are not inherited by the child even with FD_CLOEXEC cleared, and
  a dup2 file action onto the same fd (the POSIX idiom to clear CLOEXEC) is a
  no-op. Both diverge from POSIX. A dup2 action with a distinct target does
  inject the parent fd, and actions apply sequentially to the child table
  (verified with pipe-passing tests on wasmer 7.2.0).
- Consequence: anything passing pipes to a spawned child by fd number breaks
  (multiprocessing's resource tracker and spawn start method).
- Workaround: cpython's `multiprocessing-posix-spawn-wasi.patch` bounces each
  passed fd through a slot above all passed fds (`dup2 fd->tmp`, `dup2 tmp->fd`,
  `close tmp`; tmp starts at `max(128, max fd + 1)` so the slots never collide
  with the fds being placed).
- Fix: implement POSIX inheritance semantics for `proc_spawn` in wasmer: inherit
  non-CLOEXEC fds, honor same-fd dup2 as CLOEXEC clear.

### signals don't interrupt blocked pipe reads 🔴

- SIGTERM/SIGKILL to a process blocked in `read()` on a pipe neither kills it
  nor errors the read; a subsequent `waitpid` blocks forever. A child blocked in
  `sleep()` dies fine (verified with paired spawn/kill tests on wasmer 7.2.0).
  The blocked read likely parks the instance in a host-side await that signal
  delivery never cancels.
- Consequence: `multiprocessing.Pool.terminate()` (and the `with Pool(...)`
  context manager, which calls it) hangs: idle workers sit blocked in queue
  reads and can't be killed. `pool.close(); pool.join()` works because sentinels
  wake the workers first. Same risk for any subprocess kill/timeout pattern
  where the child blocks on fd reads. Also why hf-xet's SIGINT handler is a
  no-op on wasix (hf-xet-wasi-sigint.patch): a native handler would be inert
  until delivery is fixed, and CPython owns Ctrl-C at the Python boundary.
- Fix: wasmer's signal delivery must cancel in-flight blocking syscalls (EINTR
  or instance termination).

### tokio's I/O driver panics on an unexpected park errno 🟡

- Symptom: tokio panics with "unexpected error when polling the I/O driver" on
  `Unsupported` (ENOTSUP); panic=abort terminates the process.
- Workaround (`tokio/1.51.0.patch`): also tolerate `Unsupported` (ENOTSUP, errno
  58), as tokio already does for the analogous empty-poll error.
- Fix: the pinned runtime has no identified ENOTSUP path in `poll_oneoff` or
  `epoll_wait`. Capture a trace if the panic returns; otherwise drop the patch.

### `futex_wake` lost a wakeup when a waiter was mid-registration 🟢

- Symptom: a tokio worker parked on a futex never woke, hanging `join_all` and
  RustFS startup. `futex_wake` could select a waiter before its `Waker` was
  installed and skip an already sleeping waiter.
- Fix (`patches/wasmer-futex-wake-lost-wakeup.patch`): wake the first waiter
  with an installed waker, or record a bounded pending wake for a registering
  waiter. Upstreamable to wasmer.

### tokio's I/O driver compiles out the mio `Waker` on wasi 🟡

- Symptom: completions such as `tokio::fs` cannot wake a reactor parked in
  `epoll_wait`. Tokio compiles out `mio::Waker` on wasi even though the patched
  mio 1.2.2 backend provides one.
- Workaround (`tokio/1.51.0.patch`): widen those four gates to
  `any(not(target_os = "wasi"), all(target_vendor = "wasmer", tokio_wasix_waker))`,
  and opt consumers in with `RUSTFLAGS = "--cfg tokio_wasix_waker"`. The opt-in
  is required because older mio versions do not export a usable wasi `Waker`.
- Fix: once mio's upstream wasi backend ships a real `Waker` on every version in
  play, tokio can relax the blanket `not(wasi)` gate and the opt-in can go.

### host tokio panics on a cancelled `fs::File` op 🟡

- Symptom: `tokio::fs::File` stays in `Busy` when a blocking op is cancelled, so
  the next op re-polls a finished `JoinHandle` and panics ("JoinHandle polled
  after completion", `runtime/task/core.rs`). This is wasmer's own host runtime;
  the panic reaches guest stderr and fails any check comparing guest output.
- Workaround (`patches/tokio-fs-file-no-poison-on-cancel.patch`): restore
  `State::Idle` before returning the error. This is the host build's own tokio,
  not a crate compiled for the wasix target, so it is applied through a patched
  `cargoVendorDir` in `flake.nix` rather than through
  `pkgs/lib/wasix-crate-patches`.
- Fix: upstream tokio PR 8291. Drop the patch once a wasmer bump picks up a
  tokio release carrying it.

### `fd_datasync`/`fd_sync` deny with EACCES under mapped host dirs 🟢

- wasmer's `fd_datasync`/`fd_sync` return `Errno::Access` unless the fd holds
  the `FD_DATASYNC`/`FD_SYNC` right. But `path_open` computes a file's rights as
  `(requested | implied_by_open_mode) & parent_dir.rights_inheriting`
  (`path_open2.rs`, whose own TODO notes "WASI isn't giving appropriate rights
  here"): the inheriting mask on a `--mapdir`/`--volume` host preopen strips the
  implied sync rights, so files opened for writing under it cannot
  fsync/fdatasync.
- Symptom: rustfs object writes call `fdatasync` for durability; the EACCES maps
  (ecstore `to_file_error`: PermissionDenied -> FileAccessDenied) to a 500
  `InternalError "File access denied"` on every `PutObject`/`UploadPart`, while
  bucket/metadata ops (no data fsync) succeed. `mc mb` worked, `mc pipe` 500'd.
- Fix (`patches/wasmer-fd-sync-rights-durability.patch`): drop the rights gate
  in both syscalls. fsync/fdatasync are durability barriers, not security
  capabilities (POSIX needs no special permission); sync any regular-file fd.
  With the fix a full `mc` put/get round-trip against `rustfs server` passes.
- Cleaner upstream fix would stop masking implied sync rights in path_open, but
  the syscalls should not hard-deny a durability barrier either way.

### wasix Rust std does not map wasi ENOTEMPTY to `DirectoryNotEmpty` 🟡

- wasix std's error decoding returns an uncategorized `io::ErrorKind` (not
  `DirectoryNotEmpty`) for wasi `ENOTEMPTY` (errno 55). Rust code that branches
  on `err.kind() == ErrorKind::DirectoryNotEmpty` (the common "rmdir of a
  non-empty dir is fine" idiom) then falls through to its error path.
- Symptom: rustfs object DELETE (`mc rm`) 500'd with "File access denied". Its
  `delete_file` (ecstore `disk/local.rs`) tolerates NotFound + DirectoryNotEmpty
  on `remove_dir` and treats anything else as fatal `FileAccessDenied`; the
  object dir is legitimately non-empty (the xl versioned-delete rename dance
  stages old data in a sub-dir), so on wasix that ENOTEMPTY aborted + rolled
  back the delete. Traced: `path_remove_directory -> Errno::notempty` on the
  object dir.
- Workaround (`rustfs-code.patch`): `delete_file` also tolerates
  `err.raw_os_error() == Some(55)` under `cfg(target_os = "wasi")`.
- Fix: WASIX rust-std's `decode_error_kind` should map wasi ENOTEMPTY (and any
  other missing codes) to the matching `ErrorKind`, so any package keying on
  `DirectoryNotEmpty` works without per-crate patches. Broader than rustfs and
  touches the toolchain (expensive rebuild), hence the local workaround for now.

### `path_rename` mishandles hard links and replacement renames 🟡

- Wasmer recursively rebases cached inode paths after renaming a directory and
  assumed every inode reachable from that directory had a path below it. A hard
  link can make the same inode reachable outside the moved tree, so
  `adjust_path` panicked when `strip_prefix` failed and poisoned the filesystem
  lock.
- After a successful rename over an existing destination, Wasmer also retained
  the replaced destination in its inode cache instead of inserting the moved
  source entry.
- Unlink removed a hard-linked entry from the cache but skipped the host unlink
  while another link remained, leaving transaction cleanup directories
  physically non-empty.
- Unlink removed directory entries from the cache before returning `EISDIR`, so
  a remove-file-then-remove-directory probe could leave the cache inconsistent.
- Host-backed mounts did not implement `hard_link`, so `path_link` fell back to
  a cache-only alias and reported success without creating the host pathname.
- The blanket `FileSystem` implementation for dereferenceable wrappers omitted
  `hard_link`, turning supported host operations into `ENOTSUP` through `Arc`.
- Cross-directory `HostFileSystem::rename` used `fs_extra` copy/move semantics
  instead of the host's atomic rename operation.
- Symptom: RustFS beta.12 atomically publishes multipart metadata by renaming a
  transaction directory containing an inode also linked as sibling
  `part.1.meta`. `mc pipe` then hung after Wasmer panicked in `path_rename`.
- Fix (`patches/wasmer-path-rename-hardlink.patch`): rebase descendants, keep
  out-of-tree hard-link aliases unchanged, and replace the cached destination
  entry after the host rename. Materialize host hard links, forward them through
  dereferenceable wrappers, remove the cache-only success fallback, preserve
  directory entries on `EISDIR`, unlink every host pathname including non-final
  links, and use the host's rename operation. Includes unit tests for path
  rebasing. Upstreamable to Wasmer.

### `fd_filestat_get` reports a size a rename left stale 🟢

- `fd_filestat_get` returns the cached inode stat without consulting the host,
  and `path_rename` sets the target's cached size from the source inode's cached
  size rather than the host file. A path whose file is replaced by a smaller one
  therefore keeps the larger size for the life of the process, while
  `path_filestat_get` on the same path is correct.
- Symptom: `read_exact` sized from `File::metadata()` fails with `UnexpectedEof`
  on a file the process itself wrote. rustfs sizes its `xl.meta` read that way,
  so deleting an object whose metadata a multipart completion had rewritten
  smaller returned `Io error: Unexpected error` and left the object in place; a
  `cp` upload writes `xl.meta` once and is unaffected, and a restarted server
  deletes the same bytes fine.
- Fix (`patches/wasmer-fd-filestat-stale-size.patch`): take the size from the
  open handle, whose `size()` stats the host file, as `fd_sync` already does.
  Checked against wasmer 7.2.1; the whole `checks.rustfs` suite passes with it.
  Upstreamable to Wasmer.

### `fd_readdir` cookies skip entries after directory mutation 🟡

- Wasmer rebuilt and sorted the live directory listing on every `fd_readdir`
  call, then treated the caller's continuation cookie as an index into that
  changing list.
- Rust's `remove_dir_all` deletes each returned chunk before requesting the next
  one. Those deletions shifted later entries below the previous cookie, so
  Wasmer skipped the final file and `rmdir` correctly returned `ENOTEMPTY`.
- Symptom: RustFS beta.12 multipart cleanup consistently left `old.meta` or
  `old.meta.absent` in `.part-txn-settled-*` directories, causing `mc pipe` to
  fail with errno 55.
- Fix (`patches/wasmer-fd-readdir-stable-cookie.patch`): snapshot the sorted
  entries per open directory stream when reading from cookie zero, and use that
  stable snapshot for continuation calls. Duplicated descriptors share the
  snapshot. The Wasmer `fs_remove_dir_all` test now covers enough long-named
  entries to require multiple reads while deleting them. Upstreamable to Wasmer.

### spawned commands and PATH 🟢

- Fixed in current wasmer: `posix_spawnp` and fork + `execvp` both resolve the
  child via the guest PATH, and the child's `argv[0]` arrives correctly
  (verified with minimal C programs). Older runtimes could not resolve by name,
  which is why git execs absolute baked paths; that approach still works and
  stays.
- The find suite's `-exec`/xargs tests stay `broken` regardless: the spawned
  tools (cat/echo) aren't on the guest PATH at all, because the test harness
  forwards an env allowlist rather than the host PATH, so nothing exists for
  find. That is a harness/environment gap, not this issue.

### `argv[0]` 🟢

- Correct on current wasmer for both directly-run and spawned programs
  (verified). Older runtimes passed `(null)`.

### no process-table introspection 🟡

- There is no `/proc` and no process-query call, so `psutil.Process()` raises
  `NoSuchProcess process PID not found (pid=1)` for the calling process itself
  (verified under wasmer; `python/psutil/tests/basic.nix`).
  `os.sched_getaffinity` does not answer either.
- Joblib currently masks this limitation: its semaphore probe gets `ENOTSUP`
  first and disables multiprocessing, so scikit-learn's
  `_openmp_effective_n_threads()` returns one when `OMP_NUM_THREADS` is unset.
  If semaphores become available before process introspection does, joblib will
  reach the `psutil.Process()` failure again. OpenMP-parallel estimators need
  `OMP_NUM_THREADS` to use more than one thread on WASIX; both directions are
  pinned by `python/scikit-learn/tests/basic.nix`.
- Fix: answer self-inspection in wasmer (pid 1 exists, so `Process()` should
  resolve it), which also gets loky off the fallback path.

### `subprocess` rejects `cwd` with NotImplementedError 🟡

- CPython's wasm `_execute_child` refuses the options it cannot honor, so
  `subprocess.run(..., cwd=...)` raises
  `NotImplementedError: cwd is not supported on wasix` rather than running the
  child in that directory.
- Consequence: the usual guard around an optional subprocess catches `OSError`
  and `CalledProcessError`, neither of which is a `NotImplementedError`, so code
  that degrades gracefully everywhere else raises at import instead. optree's
  `version.py` shells out to `git describe` for a dev version and dies this way;
  `python/optree.nix` marks the tree as a release so the block is skipped.
- Fix: honor `cwd` by chdir'ing in the spawned child (wasix has `chdir`, and
  posix_spawn has an addchdir file action), then let CPython stop rejecting it.

### exec'ing a symlinked helper in a webc fails ENOEXEC 🟢

- `WebcVolumeFileSystem::open()` read raw (non-following) metadata, so a symlink
  resolved to `Err(NotAFile)`. Exec'ing a symlinked binary (git's
  `libexec/git-core/git-upload-pack -> ../../bin/git.wasm`, and the other git
  helpers) therefore failed with ENOEXEC ("cannot execute binary file"),
  breaking every git transport test (clone/fetch/push over local/http/https/net)
  while the same tree on a real fs works.
- Fixed: `patches/wasmer-webc-follow-symlinks.patch` resolves symlinks (relative
  targets against the link's parent, bounded loop) before opening, matching
  real-fs semantics. Verified: `checks.git` (all transport tests) passes with
  it. Vendored from python-pkgs; upstream to wasmerio/wasmer and drop once
  merged.

### `fork()` is hidden under Wasm-EH 🟡

- The sysroot hides `fork`'s declaration when `__wasm_exception_handling__` is
  defined and the symbol is absent from `libc.a` (verified: undeclared under
  exnrefEh). fork also requires an asyncified binary in every profile: the
  runtime must capture and rewind the wasm call stack, and Wasm-EH doesn't
  substitute (verified: the same fork+exec program exits 45 with no output
  without asyncify, works with it).
- Workaround: git's `wasix-compat/` shim (a `unistd.h` declaring fork + a
  `proc.c` implementing it via `__wasi_proc_fork`), reused by findutils, plus
  `WASIXCC_WASM_OPT_FLAGS=--asyncify:-O2` (below).
- Fix: expose fork from the sysroot under EH, or upstream the shim.

### `isatty` returns true for redirected stdout 🟢

- `isatty(1)` was 1 even with stdout redirected, because `fdstat` reported the
  std fds as `CharacterDevice` unconditionally. Tools colorized into files (jq
  emitted ANSI into `>file`) and git ran its pager on a pipe.
- Fixed by `patches/wasmer-isatty-non-tty-unknown.patch`: the std fds report
  `Unknown` unless the host stream is a terminal, and the `ArcFile`/`ArcBoxFile`
  wrappers forward the query (stdin is always wrapped).
- Verified: `[ -t 0/1/2 ]` under bash is y on a pty and n on a pipe.

### no default `TERM` 🟢

- wasmer started processes with `TERM` unset, so ncurses aborted with "terminals
  database is inaccessible" (less, nano) and readline dropped line editing.
- Fixed by `patches/wasmer-forward-term-on-tty.patch`: `wasmer run` forwards the
  host `TERM` when stdio is a terminal, on both the module and the webc path.
- Verified: interactive bash on a pty reports the host `TERM` and enables
  bracketed paste; less renders full-screen.

### stray "Program recieved fatal signal: Quit" on a guest exit 🔴

- A git run occasionally emits that line (wasmer's spelling) between two
  commands while still exiting 0, which fails the output comparisons:
  `checks.git.diff-compare` hit it once, having passed on the same runtime in an
  earlier run of the same tree.
- Not reproducible outside the nix sandbox: 0 of 15 runs of the same
  `git --no-pager diff` and 0 of 5 of the whole test script. Each command in the
  harness is its own wasmer process, so a late-exiting one printing after the
  next command's output fits.
- Fix: find what raises SIGQUIT at teardown. Same family as the flaky
  "JoinHandle polled after completion" in host_fs.

### no readable controlling terminal, so no pager 🔴

- A program whose stdin is a pipe reads keystrokes from the terminal instead.
  Under WASIX neither route works: `/dev/tty` is a `NullFile` (the webc runner,
  `runners/wasi_common.rs`, never calls `with_tty`, and `RootFileSystemBuilder`
  falls back to one) so it opens and reads EOF, and fd 2 is a write-only
  `host_fs::Stderr` so reading it fails at once. Verified in a guest pipeline:
  `read </dev/tty` and `read <&2` both return immediately, while `[ -t 2 ]` is
  true.
- Consequence: less draws nothing and ignores `q` (`open_tty` in its ttyin.c
  tries ttyname(2), then /dev/tty, then fd 2 — all dead ends here), so `git log`
  on a terminal hangs the moment a pager exists. Not the pager pipeline: `cat`
  as `GIT_PAGER` streams and exits 0, and `less FILE`, whose stdin is the
  terminal, is fine.
- Workaround: git ships no pager, so paged commands print directly.
- Fix: back `/dev/tty` with the host terminal in the webc runner. Two parts, and
  the first alone is not enough (tried: less then renders but still takes no
  input). (1) `RootFileSystemBuilder` must not install a `NullFile` `/dev/tty`,
  since a device that opens and reads EOF defeats every fallback. (2) The runner
  needs a readable terminal device. It cannot be `DeviceFile::new(STDIN)`, which
  is what the CLI's module path passes: `path_open` shortcuts a file reporting
  `get_special_fd()` to a dup of the _caller's_ fd, which in a pipeline is the
  pipe, so a pager would read its own output as keystrokes. It needs a
  host-terminal device reporting no special fd.

### no FIFOs, and /dev/fd had to be synthesized 🟢

- `mkfifo`/`mkfifoat`/`mknod` are absent from `libc.a` and the coreutils
  `mkfifo` fails with ENOSYS, so named pipes are not an option, and wasmer's
  virtual root synthesized
  `/dev/{null,zero,urandom,stdin,stdout,stderr,tty,shm}` but no `/dev/fd`. bash
  was built `--disable-process-substitution`.
- `/dev/fd/<n>` cannot be a file: it names the _caller's_ fd n, and a shell
  hands the path to a child that must open it and get the pipe.
- Fixed by `patches/wasmer-dev-fd.patch`: `path_open` resolves a `/dev/fd/<n>`
  path to a dup of the opener's fd n, so bash now builds with
  `bash_cv_dev_fd=standard`. Its own mkfifo-from-mknod fallback is compiled out,
  since `HAVE_DEV_FD` makes that path unreachable.
- Verified: `read < <(...)`, `cat <(...)` (the child opens the name),
  `> >(...)`, and two substitutions in one command line.

### no process groups, so no job control 🔴

- The WASIX ABI has no process-group call (`api_wasix.h` has
  `proc_fork`/`proc_spawn`/`proc_signal` and nothing else), and wasix-libc's
  `setpgid` returns EINVAL for any pid but 0 while `tcsetpgrp` writes a
  process-local variable.
- Consequence: bash is built `--disable-job-control`, so `jobs`, `fg`, `bg` and
  `disown` do not exist (verified: `type jobs` fails in the shipped webc).
  Background `&` and `wait` still work.
- Fix: process-group tracking in wasmer's control plane plus the witx calls to
  reach it, then drop the bash flag.

### `sigsetjmp` ignores the signal mask 🟡

- wasix-libc defines `sigsetjmp` as a plain `setjmp` ("TODO: ignoring signal
  masking for now" in `setjmplongjmp.c`) and the off-EH `<setjmp.h>` does not
  declare it, so a consumer that finds the symbol gets silently wrong mask
  behaviour.
- Workaround: bash and readline pass `bash_cv_func_sigsetjmp=missing` and do
  their own save/restore.
- Fix: implement the mask save/restore (musl's `sigsetjmp_tail.c` is in the tree
  but not in the build), then declare it.

### `getifaddrs`/`freeifaddrs` misnamed in wasix-libc 🟡

- wasix-libc's `ifaddrs.h` declares the standard `getifaddrs`/`freeifaddrs`, but
  `libc.a` only defines `getif_addrs`/`freeif_addrs` (verified with nm;
  python3.wasm exports only the underscored names). Callers compile, then die
  with undefined symbols at link or dylib import. `if_indextoname` and
  `if_nametoindex` are declared in `net/if.h` but not defined at all.
- Workaround: libuv's `libuv-0013-wasix-ifaddrs-names-no-if_index.patch` maps
  the names and stubs the `if_*` lookups. nix short-circuits its "are we online"
  probe instead (`unsupported-posix-apis-on-wasi.patch`).
- Fix: define the standard names in wasix-libc (alias or rename), and
  implement/stub `if_indextoname`/`if_nametoindex`.

### `mlock`/`munlock`/`madvise`/`sched_getcpu`/`sched_getaffinity` declared but unimplemented 🟢

- wasix-libc's headers declared `mlock`/`munlock`/`madvise` (`sys/mman.h`),
  `sched_getcpu`/`sched_getaffinity` (`sched.h`) but `libc.a` defined none of
  them, so callers linked an undefined dynamic import that traps at runtime
  (duckdb key pinning / allocator `madvise` / task-scheduler CPU id; opencv's
  `cv::getNumberOfCPUs()` -> `sched_getaffinity`).
- Fixed in `pkgs/toolchain/sysroot/wasix-libc-stubs.c` (globbed into the build
  via `libc-bottom-half/sources/`): best-effort no-ops (mlock/munlock/madvise
  return 0, sched_getcpu returns 0, sched_getaffinity fills the mask from
  `sysconf(_SC_NPROCESSORS_ONLN)`, and `__sched_cpucount`, which `CPU_COUNT()`
  lowers to and the libc build omits, counts the mask bits). The duckdb/opencv
  `__wasi__` guard patches are now redundant and removed. Upstream this stub
  file into wasix-libc.

### `mprotect` is not linkable 🟡

- Boost.Context's `protected_fixedsize_stack` needs `mprotect` to install a
  guard page, but wasix-libc provides no linkable implementation.
- Workaround: the Boost package aliases it to `fixedsize_stack`, preserving the
  allocator API without guard-page protection.
- Fix: implement `mprotect` for WASIX linear-memory mappings, then remove the
  package fallback.

### `<fenv.h>` omits the directed-rounding and exception-flag macros 🟡

- wasix-libc's `<fenv.h>` defines `FE_TONEAREST` and `FE_ALL_EXCEPT` (both 0)
  but not the directed-rounding modes `FE_UPWARD`/`FE_DOWNWARD`/`FE_TOWARDZERO`
  nor the individual exception-flag macros `FE_INVALID`/`FE_DIVBYZERO`/
  `FE_OVERFLOW`/`FE_UNDERFLOW`/`FE_INEXACT` (wasm has no dynamic rounding-mode
  control and no FP exceptions). The `fe*` functions (`feholdexcept`,
  `feclearexcept`, `feupdateenv`, ...) are declared and link as no-ops, but C
  code that names any missing macro gets "use of undeclared identifier" and
  fails to compile, even where it only calls it at runtime and would tolerate a
  failure/no-op.
- Consequence: `scipy.special._test_internal` (a test-only extension that probes
  directed rounding with `fesetround(FE_UPWARD/FE_DOWNWARD)`) won't compile;
  HDF5's `H5T__init_native_float_types` masks FP exceptions around NaN "don't
  care" bit probing with `feholdexcept`/`feclearexcept(FE_INVALID)`/
  `feupdateenv` and won't compile (`FE_INVALID` undeclared).
- Workaround: `python/scipy.nix` drops the `_test_internal` module (test-only,
  `install_tag 'tests'`, not imported by normal scipy);
  `wasix/hdf5/patches/hdf5-wasi-fenv.patch` guards the fe\* dance for `__wasi__`
  (nothing to mask on wasm).
- Fix: define the missing rounding-mode and exception-flag macros in wasix-libc
  (distinct int values), have `fesetround` return nonzero for anything but
  `FE_TONEAREST`, and keep `feclearexcept`/`fetestexcept` as no-ops, matching
  glibc/musl on FPUs without directed rounding or exceptions. Downstream then
  compiles unchanged.

### POSIX advisory record locking is not implemented 🟡

- WASIX supports threads and multiple processes through `thread_spawn`,
  `proc_fork`, and `proc_spawn*`, but the Wasmer WASIX ABI has no operation for
  coordinating POSIX record locks between them.
- FFmpeg 9.0's shared-cache protocol calls `flock`, which is declared in
  `sys/file.h` but absent from `libc.a`, so FFmpeg fails to link with
  `undefined symbol: flock` (verified against wasix-libc v2026-06-25.1).
- The vendored wasix-libc patch exposes `F_GETLK`/`F_SETLK`/`F_SETLKW`, the lock
  types, and `struct flock` so feature-detected consumers compile. The
  operations return `ENOSYS`; reporting success would falsely claim exclusion
  and risk cross-process corruption.
- Workaround: h5py's runtime test sets `HDF5_USE_FILE_LOCKING=FALSE`; DuckDB
  skips its lock calls on WASI in `duckdb-wasi-no-file-lock.patch`; FFmpeg links
  an `ENOSYS` stub from `ffmpeg/package.nix`.
- SQLite in WAL mode arbitrates between connections with these locks and a
  shared `mmap` of the `-shm` index, so two connections to one file race:
  garage's ten-connection pool returns `SQLITE_IOERR` ("disk I/O error") once
  more than one is in flight, which happens only under load. `garage-code.patch`
  pins the pool to a single connection, serializing its metadata access.
- Blocks the `fs2` crate, whose whole API is locking, and any crate reaching the
  filesystem through it. tantivy takes its index lock via `fs2::FileExt`, so the
  overlay registry cannot serve it from a floor patch: a port has to replace the
  mmap directory backend, as the wasix-org 0.18 source does, rather than widen a
  cfg gate.
- Fix: the in-progress implementation adds shared per-file lock state to
  Wasmer's WASIX filesystem ABI, then implements `flock` and the `fcntl` lock
  commands in wasix-libc and removes the package workarounds.

### `fd_sync`/`fd_datasync` refused a directory fd 🟢

- `fd_sync` and `fd_datasync` answered `Errno::Isdir` for `Kind::Dir` (and
  `Kind::Root`), but Linux `fsync(2)` on a directory fd is the durability
  barrier for that directory's own entries, which is how a caller persists a
  create or a rename. postgres fsyncs every directory under the data dir, so
  `initdb` died with `could not fsync file ".../base/1": Is a directory`.
- Fixed by `patches/wasmer-fd-sync-directory.patch`: both calls return success
  for a directory. Verified with a C probe doing `fsync(open(".", O_RDONLY))`,
  which reports `Is a directory` on stock 7.2.1 and succeeds with the patch.
- Neither call is a kernel-level barrier yet: `host_fs`'s `poll_flush` forwards
  to tokio's buffer flush rather than `sync_all()`, so a file fsync is not one
  either. Making a directory fsync a real barrier needs a directory-sync
  operation on the `virtual_fs::FileSystem` trait (it has none) plumbed through
  the forwarding and union implementations to `host_fs`.

### `bind` on an AF_UNIX socket fails 🔴

- Symptom: postgres logs
  `could not bind Unix address "/pg/.s.PGSQL.5432": Success`, then
  `FATAL: could not create any Unix-domain sockets` (verified against wasmer
  7.2.1; the errno it reports is not even set).
- Consequence: a server that offers a local socket alongside TCP has to be told
  to skip it. postgres needs `-c unix_socket_directories=` before it will start,
  and its client tools have to be given `-h <host>` rather than the default
  local socket.
- Fix: implement AF_UNIX `bind`/`connect` in wasmer's WASIX socket layer.

### System V IPC is absent from wasix-libc 🟡

- Symptom: `fatal error: 'sys/ipc.h' file not found`, then the same for
  `sys/shm.h`. No sysroot ships `sys/ipc.h`, `sys/shm.h` or `sys/sem.h`, and
  `libc.a` carries no `shmget`/`shmat`/`shmdt`/`shmctl` (verified against
  wasix-libc v2026-07-30.1).
- Consequence: postgres links its shared-memory segment against System V under
  every non-Windows configure template, so the server does not compile at all.
  Semaphores are unaffected: the linux template already prefers unnamed POSIX
  ones, which wasix-libc defines.
- Workaround: `postgresql/wasix-compat/shm.c` declares the API and backs
  segments with process-local heap memory. A key this process did not create
  reports ENOENT, which postgres reads as "no other server owns this data
  directory"; that is only correct because `proc_fork` hands the child a copy of
  the linear memory, so no segment could be shared across processes anyway.
- Fix: shared memory objects in wasmer's WASIX ABI plus the libc wiring. That is
  also the prerequisite for a multi-user postmaster, whose backends need one
  buffer pool.

### `dladdr` missing from wasix's dyld 🟡

- wasix provides `dlopen`/`dlsym`/`dlclose`/`dlerror`, but not `dladdr` (the
  reverse lookup: address -> containing shared object + path). A wheel whose
  extension module references `dladdr` loads fine until the symbol is resolved,
  then wasmer aborts import with "Dynamically-linked symbol not found or has bad
  type: dladdr". Distinct from the link-time libc gaps above: the symbol is a
  dynamic (dyld) import, so it surfaces only when the `.so` is loaded under
  wasmer, not at build.
- Consequence: onnxruntime's `Env::GetRuntimePath` calls `dladdr` to find the
  directory of its own binary (to locate provider shared libraries beside it);
  `import onnxruntime` traps.
- Workaround: `wasix/onnxruntime/patches/onnxruntime-wasi-no-dladdr.patch`
  guards the `dladdr` path on `__wasi__` (as onnxruntime already does for AIX),
  taking the non-`dladdr` fallback. Fine for a static single-EP build that loads
  no provider `.so`.
- Fix: implement `dladdr` in wasix's dyld (fill `Dl_info` from the module
  table), or at least export a weak stub returning 0 so consumers take their own
  fallback instead of failing to import.

### `dlfcn.h` ships for `off` but not the non-PIC EH sysroots 🟡

- `Makefile-eh` omits the header when PIC is off
  (`MUSL_OMIT_HEADERS += "dlfcn.h"` under `ifeq ($(PIC), no)`), while the plain
  `Makefile` the `off` profile uses has no such rule. So `sysroot` (off),
  `sysroot-ehpic` and `sysroot-exnref-ehpic` carry `dlfcn.h`; `sysroot-eh` and
  `sysroot-exnref-eh` do not (verified against the built sysroots).
- Consequence: a package that includes `<dlfcn.h>` unconditionally compiles at
  `off` and the PIC profiles but fails at `eh`/`exnrefEh` with "'dlfcn.h' file
  not found", which reads as a missing feature rather than a header-install
  rule. duckdb hits this in `src/include/duckdb/common/dl.hpp`, so it is
  restricted to the PIC profiles.
- The gate is defensible (wasm `dlopen` needs side modules, hence PIC), but the
  two makefiles disagree, and `off` is non-PIC too.
- Fix: make the rule consistent across both makefiles. If the header is meant to
  track dlopen support, omit it for `off` as well; if it is meant to track the
  declarations, ship it everywhere and let the link fail instead.

### `sys/syslog.h` and `sys/sysmacros.h` absent 🟡

- `syslog.h` ships, but the legacy `sys/syslog.h` spelling does not (verified
  against the built sysroot), and `sys/sysmacros.h` is missing entirely, so
  `makedev`/`major`/`minor` have no declaration. `sync()` is also undeclared.
- Consequence: util-linux's `libcommon` does not compile, and every util-linux
  program links it, so the package builds `libuuid` only (cpython's `_uuid`
  backend). `lib/configs.c` needs `sys/syslog.h`; `lib/path.c` and `lib/sysfs.c`
  need `makedev`/`minor` (they compile in under `HAVE_OPENAT && HAVE_DIRFD`,
  which wasix satisfies). `libblkid`, `libfdisk`, and `fsck.minix` additionally
  need `sync()`.
- Fix: add a `sys/syslog.h` wrapper including `syslog.h`, a `sys/sysmacros.h`
  with the usual `makedev`/`major`/`minor` macros, and a `sync()` stub in
  `wasix-libc-stubs.c`. That unblocks most util-linux programs; the rest need
  `fork` (`off` only), `sys/ipc.h`, or `PRIO_*`/`get,setpriority`.

### `statvfs` fails on a `--mapdir` directory 🟡

- `statvfs()` on a host directory mounted with `--mapdir`/`--volume` returns
  ENOTSUP, so free-space checks fail. nix's local store calls it on every
  operation that could trigger GC, which makes `nix --store /some/dir` unusable
  (`nix eval --store dummy://` is unaffected: no filesystem, no statvfs).
- Fix: report the backing filesystem's numbers (or plausible ones) for mounted
  host directories.

## Toolchain

### apr cannot spawn a process 🟡

- `apr_proc_create` builds its child with fork, and fork is declared only when
  wasm exception handling is off, so the EH profiles fail to compile it with
  "use of undeclared identifier 'fork'" (verified against wasix-libc's unistd.h,
  which gates the declaration on `!defined(__wasm_exception_handling__)`).
- Consequence: apr consumers cannot run a helper program. Subversion loses
  `svn+ssh://` and external diff and editor commands; the rest of it, including
  http and https access through serf, is unaffected.
- Workaround: `packages/apr/patches/wasi-unsupported-calls.patch` answers
  APR_ENOTIMPL, alongside `apr_proc_fork` and `apr_proc_detach`, which have no
  equivalent at all.
- Fix: build the child through `posix_spawn`, whose wasi file actions cover what
  apr needs here (`addclose`, `addopen`, `adddup`, `addchdir_np`). Its
  user-switching and rlimit options stay unimplementable.

### wasixcc only reads link inputs whose name ends in `.o` 🟡

- Linking a shared library from an object named `foo.os` fails with
  `wasm-ld: error: cannot open <tmpdir>/foo.os.0.o: No such file or directory`,
  while the same bytes named `foo.o` link. The name is the only difference, so
  wasixcc selects on the extension; what it means to write at
  `<tmpdir>/<name>.0.o` is not visible from outside (verified against wasixcc
  0.4.5, clang 21.1.206).
- Consequence: scons builds, which name shared objects `.os` by default, cannot
  link a shared library at all.
- Workaround: `packages/serf/patches/wasi-shared-object-suffix.patch` sets
  scons' `SHOBJSUFFIX` to `.shared.o`.
- Fix: have wasixcc classify link inputs by content, or accept the other object
  suffixes in common use.

### wasixcc drops the sysroot when the input is stdin 🟡

- `echo '#include <errno.h>' | wasixcc -E -` fails with
  `<stdin>:1:10: fatal error: 'errno.h' file not found`, while the same source
  in a file preprocesses fine. wasixcc passes the compiler only
  `--target=wasm32-wasi -fuse-ld=...` for the stdin form, so the include search
  is clang's builtin directory alone (verified against wasixcc 0.4.5, clang
  21.1.206).
- Consequence: any build step that pipes source into the compiler sees the
  sysroot as empty. perl's `ext/Errno` harvests its error list that way and
  reports "No error definitions found"; autoconf probes of the `cpp -` form
  would misreport every header as missing.
- Workaround: `packages/perl/patches/wasi-errno-cpp-file-argument.patch` passes
  the file as an argument, the way perl's own MSWin32 branch already does.
- Fix: have wasixcc inject the sysroot and include flags for stdin input as it
  does for a named source file.

### a wasix-hosted flang cannot run its codegen job 🔴

- `flang -c x.f90` schedules a clang `-cc1` command and spawns it; the spawn
  fails with `posix_spawn failed: Exec format error`, the same shape as find's
  `-exec` and xargs. Declaring `wasmer/clang` as a webc dependency does not make
  it resolvable.
- Workaround: `pkgs/overlays/f/flang/wasix.nix` is `passthru.wasix.broken` and
  not shipped. The host flang (`pkgs/overlays/w/wasix-flang/`) is unaffected and
  builds Fortran for scipy.
- Fix: make a dependency's command resolvable to a spawning guest, or give flang
  the in-process frontend dispatch clang has for `cc1`.

### flang folds constants at one rounding mode 🟡

- wasm exposes neither directed rounding nor floating-point exception flags, so
  its `fenv.h` defines only `FE_TONEAREST`. `flang/lib/Evaluate/host.cpp` sets
  the host rounding mode and reads the exception flags while folding constants.
- Workaround: `wasm32-fenv.patch` maps the directed modes onto round-to-nearest
  and reads the flags as clear, so folding under `ROUND='UP'` and friends
  silently uses the wrong mode rather than failing.
- Fix: honour the requested mode in software, or diagnose the unsupported ones
  the way flang already does for `TiesAwayFromZero`.

### flang assumes a 64-bit host 🟡

- `flang/CMakeLists.txt` refuses any target whose pointers are 32 bits, and
  `lib/Evaluate/constant.cpp` narrows 64-bit subscripts into `size_t`.
- Workaround: `wasm32-pointer-width.patch` exempts wasm from the refusal and the
  package downgrades `c++11-narrowing`; a wasm32 address space cannot hold an
  object whose subscript needs the discarded bits.
- Fix: upstream flang should size its subscript types off the target.

### wasix-libc exports `sigaltstack` but hides its API 🟡

- LLVM's CMake symbol check finds `sigaltstack`, but wasix-libc guards the
  declaration and `SS_ONSTACK` behind `__wasilibc_unmodified_upstream` with the
  comment "WASI has no signals". LLVM consequently enables alternate signal
  stacks and then fails to compile against `signal.h`.
- Workaround: the LLVM package configures `HAVE_SIGALTSTACK=OFF`. LLVM's signal
  handling otherwise works without an alternate stack.
- Fix: wasix-libc should expose the `sigaltstack` declaration and constants when
  the exported implementation is supported, or stop exporting the symbol so
  feature checks consistently reject it.

### wasix-libc declares memory-advice/protection APIs without definitions 🟡

- `sys/mman.h` declares `posix_madvise` and `mprotect`, but no sysroot archive
  defines either symbol. LLVM consequently compiles its optional mapped-file
  eviction and protection operations and fails when linking every tool.
- Workaround: `support-wasix.patch` makes LLVM's `mapped_file_region::dontNeed`
  and `Memory::protectMappedMemory` no-ops on WASIX. Linear WebAssembly memory
  has no per-page protection, so both operations are only hints there.
- Fix: implement successful no-op definitions in wasix-libc, or remove the
  declarations and advice constants until implementations exist.

### wasixcc rejects `-fno-exceptions` under forced EH; stripped in the shim 🟡

- wasixcc hard-errors on `-fno-exceptions`/`-fno-cxx-exceptions` in the PIC
  profiles ("PIC without wasm exceptions is not a valid build configuration"):
  PIC needs wasm EH. Many exception-free C/C++ libraries pass those flags.
- Workaround (in place): `set/stdenv.nix`'s shim strips both flags in every EH
  profile (the `off` profile keeps them, where a throwing TU genuinely can't
  build). Mirrors `set/rust-platform.nix`'s `mkDepCc` for cc-rs. It STRIPS (not
  a last-wins `-fexceptions`): wasixcc errors on merely seeing the flag. Must
  also rewrite the cc-wrapper's `@response-file` (long compiles collapse flags
  into it, so argv-only stripping misses them: crc32c). Deleted the per-package
  seds (crc32c, libhwy, libjxl, numpy).
- Root fix: wasixcc should tolerate `-fno-exceptions` as a no-op under forced EH
  (like `WASIXCC_DISCARD_UNSUPPORTED_FLAGS`), then the shim strip can go.

### Rust cdylib wheels ship legacy Wasm-EH from the rust `-dl` sysroot 🟡

- Symptom: a maturin wheel containing libc++ exception code fails validation
  with "legacy_exceptions feature required for try instruction". The Rust `-dl`
  target links the legacy-EH PIC sysroot, while wasmer 7.2.0 accepts the exnref
  encoding. Cargo-wasix translates CLI `.wasm` files but not wheel `.so` files.
- Workaround (in place): a setup hook on the shared `maturinBuildHook`
  (`exnrefTranslateHook`) runs `wasm-opt --translate-to-exnref` on wheel `.so`
  files. Tokenizers imports; pure-Rust jiter and pydantic-core are unchanged.
- Fix: point the Rust targets at the exnref sysroots, or make cargo-wasix expose
  cdylib post-processing. Setuptools-rust needs the hook if a wheel containing
  legacy EH appears there.

### asyncify can't process Wasm-EH instructions 🟡

- `wasm-opt --asyncify` aborts ("unexpected expr type", Flatten.cpp) on modules
  containing EH instructions. Under the EH profiles that means C++ exceptions or
  anything using setjmp/longjmp (lowered to Wasm-EH SjLj): verified with a C++
  binary, and reproduced by git's clar unit-tests binary (clar uses setjmp).
  Plain C without setjmp asyncifies fine regardless of feature flags.
- Workaround: fork-using C programs (git, findutils) set
  `WASIXCC_WASM_OPT_FLAGS=--asyncify:-O2`, so wasixcc's link-time wasm-opt
  applies the pass in the EH profiles like it does on its own in the off
  profile. git additionally skips building its test binaries (`TEST_PROGRAMS=`,
  `CLAR_TEST_PROG=`), which contain setjmp and can never run in a cross build.
  coreutils has no such seam (the setjmp reaches the one multi-call binary), so
  it is off-EH only, like bash.
- Fix: binaryen asyncify support for EH; upstream the wasixcc setting.

### `wasm-opt` corrupts autoconf/cmake feature detection 🟡

- A failing wasm-opt run on a throwaway conftest makes `configure`
  false-negative a feature (sqlite: "Cannot find libm functions").
- Root cause (re-verified 2026-07-13, thrift at eh): function-exists probes
  declare wrong signatures (`char strerror_r();`); wasm-ld silently links that
  into invalid wasm, and wasm-opt fatals parsing it. Only eh is hit: wasixcc
  always appends `--emit-exnref` there, so wasm-opt runs even for -O0 probes;
  the other profiles skip it (no passes at -O0).
- Workaround: `disableWasmOptInConfigureHook`, opt-in per package (sqlite,
  libzip, thrift).
- Fix: wasm-ld should reject signature-mismatched direct calls (WASIX LLVM), or
  wasixcc's autoconf workarounds mode skips post-link wasm-opt.

### non-default python splices a wasm `pyproject-build` in nativeBuildInputs 🟡

- The default python is py314. A package that runs `pyproject-build` directly
  (from `build` in nativeBuildInputs, as the C++ onnx does in preBuild, rather
  than via `pypaBuildHook`) builds fine on py314 but on py313 (non-default)
  `build` splices to the wasm target: its `.pyproject-build-wrapped` is a python
  script, and bash runs it and chokes on the `lambda` in the site-init line. The
  pythonOnBuildForHost native `build` exists; the nativeBuildInputs splice just
  does not pick it in the non-default python's package set.
- Consequence: the C++ onnx re-instantiated in the python313 set fails; and it
  is re-instantiated per interpreter because the python onnx wheel pulls `onnx`
  (C++) through its own set. (An earlier abi3-dist `.override` that forced the
  py314 C++ onnx worked for py314 but dragged its py314 python + protobuf onto
  the py313 wheel's PYTHONPATH, which shadowed py313's build tools, so the
  `packaging`/`installer` failures seen then were that pollution, not a real
  py313 provisioning gap.)
- Workaround: `python/onnx.nix` repackages only the abi3 wheel FILE from the
  top-level (native) py314 C++ onnx and drops the onnx package from
  build/propagated inputs, so no per-interpreter C++ onnx is built and no py314
  python leaks. Both py313 and py314 wheels import green.
- Fix: make the non-default python's package set splice `build` (and peer pypa
  tools) to `pythonOnBuildForHost` in nativeBuildInputs, matching the default,
  so a package that must genuinely build a wheel on py313 works.

### flang cross-compiles wasm32 with the host ABI 🟡

- flang assumes host and target share an ABI, which breaks a 64-bit host
  targeting 32-bit wasm32. Building and linking Fortran hit three gaps, all in
  the flang frontend (patched in `toolchain/flang.nix`, which builds a
  wasm32-only cross flang):
  - No wasm case in flang's per-arch ABI lowering
    (`Optimizer/CodeGen/Target.cpp`); `flang-wasm32-target.patch` adds
    `TargetWasm32` (complex byval/sret, clang's WebAssembly ABI).
  - The `_FortranA*` runtime interface sizes `size_t`/`long` from the _host_
    compiler's `sizeof` (`RTBuilder.h`), so a 64-bit host emits i64 lengths
    where the wasm32 flang-rt uses i32: a wasm-ld signature mismatch on
    `_FortranAioOutputAscii` etc. `flang-wasm32-runtime-abi.patch` pins those
    pointer-width runtime types to 32 bits.
  - flang emits a 3-arg POSIX `main(argc,argv,envp)`; wasi-libc's `__main_void`
    calls a 2-arg `main(argc,argv)`, an unresolvable signature mismatch
    ("undefined symbol: main"). `flang-wasm32-main.patch` emits a 2-arg main on
    wasm and hands ProgramStart a null envp (the runtime ignores it and reads
    libc `environ`).
- These patches hardcode wasm32 widths / a 2-arg main; safe only because
  `toolchain.flang` targets wasm32 exclusively.
- The runtime itself (`toolchain.flangRt`, `flang-rt.nix`) cross-builds with two
  more fixes: `-Wno-c++11-narrowing` (flang-rt narrows uint64 byte sizes into
  32-bit size_t in braced initializers, ill-formed on wasm32; every value fits
  the 4 GiB heap so the truncation is lossless) and
  `flang-rt-execute-no-fork-on-wasi.patch` (async EXECUTE_COMMAND_LINE forks,
  but fork is hidden under Wasm-EH, above, and there is no shell to exec; report
  it unsupported).
- Fix: upstream flang should derive the runtime-interface integer widths from
  the target data layout (not host `sizeof`) and emit a target-appropriate main
  entry; then all four workarounds drop.

### a Fortran COMMON block segfaults flang for wasm32 🟡

- **Symptom**: flang dies with no diagnostic while emitting a wasm32 object for
  any COMMON block. Two narrower reproducers show it is not a flang bug:

  ```
  clang --target=wasm32-unknown-wasi -fcommon -c x.c   # int x;
  echo '@c_ = common global [4 x i8] zeroinitializer' > ir.ll
  llc -mtriple=wasm32-unknown-wasi -filetype=obj ir.ll
  ```

  `MCWasmStreamer::emitCommonSymbol` is an `llvm_unreachable`, which a release
  build compiles to `__builtin_unreachable`, so the caller runs into UB and dies
  in the unwinder. An assertions build prints the message instead.

- **Consequence**: any Fortran declaring COMMON. clang has defaulted to
  `-fno-common` since clang 11 and reference LAPACK declares none, so scipy's
  bundled PROPACK is the first to reach it. Checked against LLVM 21.1.2.
- **Workaround**: `flang-wasm32-common-linkage.patch` gives COMMON blocks weak
  linkage on wasm. Implementing common symbols in the wasm object writer is the
  wrong fix, since wasm-ld has no common-symbol concept; weak links, at the cost
  of silently taking one size if two units declare the block differently.
- **Fix**: lower COMMON per target in upstream flang, and cherry-pick
  llvm-project main's `getContext().reportError` for both stubs onto
  wasix-org/llvm-project so the crash reports itself. release/21.x carries
  neither.

### scipy calls the flang reference BLAS/LAPACK without F77 hidden CHARACTER lengths 🟢

- Symptom: scipy's C and Cython BLAS/LAPACK wrappers omit the hidden `size_t`
  length for each Fortran `CHARACTER*1` argument. Wasm's strict call signatures
  turn that mismatch into traps such as `signature_mismatch:dgemm_`.
- Fix: `scipy-cython-blas-fortran-charlen.patch` corrects the generated
  `cython_blas` and `cython_lapack` calls without changing their public API.
  `scipy-hand-c-blas-fortran-charlen.patch` wraps scipy's hand-written calls and
  corrects the `?getrf`/`?getri` return type. `scipy/tests/basic.nix` covers the
  affected optimize, integrate, matrix-function, batched-linalg, and solver
  paths; scikit-learn covers the Cython path.
- Upstream: scipy should pass the hidden lengths unconditionally, as its f2py
  wrappers already do. `chla_transtype_`, which scipy does not call directly,
  still has its separate character-return ABI warning.

### `clang-scan-deps` breaks cmake try-compiles 🟡

- The wasix cross cc is `isClang` (set/stdenv.nix), so nixpkgs puts
  `clang-scan-deps` on PATH and cmake turns on C++ module scanning for Ninja
  C++20 builds. cmake then scans not just real sources but the throwaway
  `check_cxx_source_compiles`/`try_compile` probes it runs at configure time.
  `clang-scan-deps` fails on those probe compiles for our wasm target (it is
  invoked directly by cmake, not through the wasixcc shim, so it does not get
  the sysroot/target flags the shim injects), and cmake reads every failed scan
  as "the probe did not compile."
- Consequence: a package whose configure does try-compiles aborts with a
  misleading message. rapidfuzz's LLVM-style atomic check fatals with "No native
  support for std::atomic<int>" though the probes compile fine with scanning off
  (all HAVE*CXX_ATOMICS*\* pass). duckdb and pyzmq have no such probe and build
  with scanning on.
- Workaround: a set-wide setup hook in `set/stdenv.nix` defaults
  `-DCMAKE_CXX_SCAN_FOR_MODULES=OFF` for every cmake build (harmless where cmake
  never scans; no per-package opt-out needed).
- Fix: make `clang-scan-deps` see the wasix sysroot/target on try-compiles (wire
  it through the shim, or export the flags cmake forwards to it) so scanning
  actually works, then drop the hook. Scanning is off because it misreports
  probes, not because C++20 modules are unwanted.

### protobuf 4's C++ python extension links without abseil 🟡

- protobuf's python `setup.py` gives the `google.protobuf.pyext._message`
  extension `libraries=['protobuf']` and nothing else, because on a
  shared-object platform `libprotobuf.so` carries abseil transitively. A static
  cross build has no such closure, so abseil stays undefined and wasm-ld turns
  each reference into a module import.
- Consequence: importing the extension aborts with
  `Unresolved global 'GOT.mem'._ZN4absl...MixingHashState5kSeedE due to: Missing export`.
  Only the 4.x wheel is affected: 5.x and later select the upb backend, which is
  C and uses no abseil. `api_implementation` catches the ImportError and falls
  back to the pure-python backend, so `import google.protobuf` still works, one
  order of magnitude slower and with none of the C++ descriptor pool semantics.
- Workaround: the `wheel-py313-protobuf4` entry in `python/wheels/default.nix`
  imports `google.protobuf.internal._api_implementation`, nixpkgs' own check
  that `--cpp_implementation` took effect, instead of the extension the other
  protobuf entries import. The wheel ships and degrades quietly, so nothing
  reports the slower backend.
- Fix: put the abseil archives on the extension's link line in the order
  `pkg-config --libs protobuf` reports, keeping them after the objects that
  reference them.

## Packages that don't cross-build

- **tzdata** 🟡: `localtime.c` needs getresuid/tzname/…, absent on WASIX.
  Dependents use build-platform tzdata (zoneinfo is platform-independent data):
  jq, python3.
- **libffi** 🟡: nixpkgs libffi has no wasm32-wasi port; `wasix-org/libffi` adds
  one.
- **pcre2grep callout-fork** 🟡: uses fork(); `--disable-pcre2grep-callout-fork`
  (the library is unaffected).
- **hydra-queue-runner --status** 🟡: exits through
  `RuntimeError: uninitialized element` in `prometheus::Registry::~Registry()`,
  reached from `State::~State()`. The path that takes a status snapshot and
  returns is the only one that runs the destructor; the daemon loop, which is
  how the queue runner is actually run, is unaffected and serves its metrics. An
  uninitialised table element is an indirect call to a slot the PIC build never
  filled, so the suspect is the registry's cross-module vtable rather than
  anything hydra does.
- **breezy** 🔴: `brz` is a setuptools-rust `Binding.Exec` that embeds CPython,
  so it links libpython. Our CPython is ehpic-only and reaches its extensions
  through dlopen, and no sysroot defines dlopen or mmap for a static link, so
  libpython's `dynload_shlib.o` and `mmapmodule.o` come up undefined. The
  wheel's own extensions do build: rustc needs the directory holding libpython
  on its search path rather than PYO3_CROSS_LIB_DIR's sysconfig one, and the
  readdir accelerator calls fchdir, which wasi-libc has no declaration or symbol
  for. hydra drops bzr from its VCS tools. Fix: a dlopen-free static CPython to
  embed, or link brz against the dl target.
- **darcs** 🔴: GHC's wasm backend panics compiling atomic primops:
  `wasm32-wasi-ghc: panic! ... onCmmLocalReg_Typed: unreachable` on
  atomic-counter 0.1.2.4 (GHC 9.12.4.20260731). Needs a fix in GHC, not here.
  hydra drops it from its VCS tools and keeps git, mercurial and subversion.
- **glib** 🟡: never built on wasix. Its bundled gnulib builds broken math
  replacements (meson `cc.links` fails wholesale on this cross-static stdenv, so
  every math fn is "missing"; `isinf.c` is Visual-Studio-only) and GIO needs
  socket ancillary data (`struct cmsghdr`/`CMSG_*`/`SCM_RIGHTS` sit behind
  `__wasilibc_unmodified_upstream`, which wasi-libc compiles out), plus fork for
  GSpawn/GResolver. Pulled only by matplotlib → libraqm → harfbuzz's optional
  hb-glib; `packages/harfbuzz.nix` disables harfbuzz's glib/gobject features and
  drops the input (libraqm uses harfbuzz's core shaping API, not hb-glib). Fix:
  port glib (substantial) or keep hb-glib off.
- **graphite2** 🟡: its docs build a `python3.withPackages` env that
  cross-instantiates and fails to compile on wasix (`--ld-path` unused, then
  `-Werror`). Only pulled by harfbuzz's Graphite shaping, which libraqm doesn't
  use; `packages/harfbuzz.nix` sets `withGraphite2 = false`.
- **boost** 🟡: Boost.Build (b2) rejects `architecture=wasm` ("not a known value
  of feature <architecture>"), so nixpkgs' cross boost never configures. Its
  only wasix consumer so far is scipy, which needs the header-only boost.math;
  `python-packages/scipy.nix` uses the build-host boost's headers
  (`BOOST_INCLUDEDIR`/`BOOST_LIBRARYDIR`, both required by meson's boost
  detection) instead of cross-building. Fix (for a real wasix boost): teach b2 a
  `wasm`/`wasm32` architecture value (or map it to a no-op), then build
  header-only or the subset that compiles.
- **qhull** (not broken, packaging quirk) 🟢: the static-only wasix build makes
  `libqhullstatic_r.a`, but qhull_r.pc and consumers link `-lqhull_r` (the
  shared-build name); `packages/qhull.nix` aliases the static archives under the
  `-lqhull_r`/`-lqhull` names.

## Rust

### rustc incremental compilation requires file locking 🟡

- The WASIX stdlib reports `File::lock` as unsupported because the WASIX ABI has
  no cross-process advisory locking operation. rustc therefore rejects its
  incremental session directory before compiling a crate.
- Workaround: the hosted Cargo command sets `CARGO_INCREMENTAL=0`.
  Non-incremental builds remain correct and avoid pretending that lock
  acquisition succeeded.
- Fix: add shared advisory locking to the Wasmer WASIX filesystem ABI, implement
  it in wasix-libc and Rust std, then remove the command environment override.

### WASIX-hosted Cargo dependencies assume `cfg(unix)` 🟡

- Cargo's default `git2` features enable SSH, which builds bundled libssh2
  against OpenSSL. The toolchain sysroot does not contain target OpenSSL, so a
  WASIX-hosted Cargo fails while compiling `libssh2-sys`.
- Workaround: `toolchain/rust/wasix-host-tools.patch` disables `git2` default
  features. Cargo's HTTP Git transport remains provided by `git2-curl`; SSH Git
  URLs are unavailable in the hosted package. The patch also supplies the
  missing WASIX process, pipe, path, and symlink branches in `cargo-util`.
  Central vendor patches provide WASIX path and descriptor handling for `curl`
  and `curl-sys`, provide byte-preserving WASIX paths in `git2`, select the
  WASIX directory-symlink and stat-layout branches in the `gix` crates, and
  select pthreads for bundled libgit2.
- Fix: make the wasix-org/rust Cargo build explicitly select supported Git
  transports, upstream the `cargo-util` WASIX branches and WASIX target handling
  to those crates, and stabilize the WASIX std APIs Cargo needs.

### `static-web-server` assumes Unix or Windows 🟡

- Path decoding and server completion are selected only by `cfg(unix)` or
  `cfg(windows)`, so WASIX has no byte-to-path implementation and leaves its
  server futures unused under `deny(warnings)`.
- Workaround: `wasix-target.patch` uses WASI byte paths and awaits the HTTP
  server futures without installing the Unix signal-hook handlers.
- Fix: upstream a WASI/WASIX platform arm; graceful shutdown can be added when
  the program has a portable signal source for WASIX.

### the rust target's self-contained lib dir holds only `libc.a` 🟡

- A build script emitting `cargo:rustc-link-lib=pthread`, as pkg-config's
  `Libs.private` produces for any POSIX stub library, fails with
  `rust-lld: error: unable to find library -lpthread`, even though the wasix
  sysroot ships an empty `libpthread.a`. rustc searches only
  `lib/rustlib/wasm32-wasmer-wasi/lib/self-contained`, which holds `libc.a`
  alone, and it does not search a nix `buildInputs` entry's libdir either.
- Consequence: hits any Rust package that links a C library through pkg-config
  (verified on wasix-rust-toolchain 2026-08-06.1).
- Workaround: `garage/package.nix` puts the profile sysroot's lib dir and zlib's
  on `RUSTFLAGS` as `-L` entries.
- Fix: install the sysroot's stub archives alongside `libc.a` in the rust
  target's self-contained directory, or add the sysroot lib dir to the target
  spec's link search.

### `garage` reaches for Unix-only services with no other arm 🟡

- Its API and web servers bind either a TCP socket or a
  `tokio::net::UnixListener`, shutdown comes from `tokio::signal::unix`, free
  space from `nix::sys::statvfs`, and the RPC public address is autodetected
  with `pnet_datalink`. Each is selected by `cfg(unix)` alone, so a WASIX build
  stops at `std::os::unix::fs::PermissionsExt` before it reaches them. The one
  `cfg(unix)` field upstream does gate, `Secrets::allow_world_readable_secrets`,
  is then read without a gate.
- Consequence: unix-socket bind addresses, signal-driven shutdown, and the free
  space a node reports to its peers are all unavailable in the wasm build, and
  `rpc_public_addr` has to be configured rather than discovered. `db_engine`
  must also be set to `sqlite`, the one engine that opens: `lmdb` is not
  compiled in and `fjall` fails its own open with `EISDIR`.
- Workaround: `garage-code.patch` supplies the missing arm at each site, and
  `garage-manifest.patch` moves `nix` and `pnet_datalink` behind `cfg(unix)` so
  neither is compiled for wasm.
- Fix: a portable signal source and interface enumeration for WASIX (see
  `getifaddrs`/`freeifaddrs` above), plus AF_UNIX in mio's WASIX backend.
  Verified against wasmer 7.2.1 and garage 1.3.1.

### `polling` has no WASIX backend 🟡

- `polling` 3.11 rejects `wasm32-wasmer-wasi`; its portable fallback is limited
  to Unix-like targets and depends on `rustix` pipe support, which is compiled
  out for WASI.
- Workaround: the vendored crate patch selects a WASIX epoll backend with an
  eventfd notifier, allowing consumers such as `async-io` to build.
- Fix: upstream the WASIX backend to `polling`. It uses the existing WASIX epoll
  API directly rather than routing through `rustix`'s WASI preview backends.

### library/Cargo.lock pins libc 0.2.183 from two sources 🟡

- std depends on WASIX libc via a direct git dependency while the other library
  crates (dlmalloc, panic_unwind, std_detect, test, unwind) stay on registry
  libc. Since the WASIX port matches the version the workspace resolves (both
  0.2.183 as of v2026-07-07.2+rust-1.96), the lockfile carries the same
  name+version from two sources: importCargoLock keys vendor dirs by
  name+version, the second symlink collides, and the toolchain cannot be
  vendored. Wasix std also mixes crates built against two different libcs.
- Workaround: `toolchain/rust/libc-patch-crates-io.patch` routes crates-io libc
  to the WASIX source via `[patch.crates-io]` (applied in postPatch);
  `library.Cargo.lock` is the matching regenerated lock for vendor.nix.
- Fix: merge the patch into wasix-org/rust; drop both files (and the
  rust-toolchain update note) with the first tag that includes it.

### Rust binaries exited 70 in std init: toolchain built on the stable channel 🟢

- rustc only emits `--max-memory=4GiB` for a shared (threaded) memory off the
  stable channel; built on stable, the memory came out non-growable and the
  first allocation in std startup trapped, `_Exit(70)` before main. The
  toolchain builds with `--release-channel=nightly` (see
  `toolchain/rust/toolchain.nix`); nothing needed per package.

### getrandom 0.3 doesn't recognise the target 🟡

- "Unknown version of WASI" on `wasm32-wasmer-wasi`. CLI crates built through
  cargo-wasix need no workaround. Some python wheels pulling getrandom 0.3
  (bcrypt, pydantic-core) still pin `wasix-org/getrandom`; its backend adds a
  dependency on the `wasix` crate, which a vendor patch can't introduce (see
  `python/lib/rust.nix`). The dependency-free vendor patch below is preferred
  and has replaced that source override for jiter.

### getrandom 0.3/0.4 fixed by selecting the p1 backend 🟡

- Both getrandom 0.3.4 and 0.4.3 ship a `wasi_p1` backend that is a raw
  `extern "C" random_get` from `wasi_snapshot_preview1` (which wasix libc
  provides) with **no crate dependency**, but their `backends.rs` only picks it
  under `#[cfg(target_env = "p1")]`, and our target's env isn't p1, so they fall
  to the component-model backend and `compile_error!` ("Unknown version of
  WASI"). No alternate source or `wasix` crate is needed; just reroute the
  selection.
- Workaround: `lib/vendor-getrandom-wasi.nix` (helper
  `rust.patchVendoredGetrandomWasi`) patches vendored getrandom 0.3/0.4
  `backends.rs` to use `wasi_p1` for anything that isn't p2/p3, and refreshes
  the checksum. Used by `jiter.nix`/`uuid-utils.nix`/`fastuuid.nix` with no
  `[patch.crates-io]` source override and no shipped lock. This is simpler than
  the getrandom-0.3 override above and should replace it for bcrypt and
  pydantic-core too.
- Fix: our wasix rust target should report `target_env = "p1"` in its target
  spec; then getrandom (and any preview1 crate) picks the right backend with no
  patch at all.

### libdatadog treats every wasm32 target as browser wasm 🟡

- libdatadog v35 (ddtrace 4.x) cuts threads, sockets and its native hyper HTTP
  stack out of every wasm32 build: `libdd-common`'s `connector`, `http_common`
  and `threading`, `libdd-capabilities`' `MaybeSend` (`Send` becomes a blanket
  impl), `libdd-shared-runtime`'s `Worker` (`async_trait(?Send)`), plus module
  and dependency cutouts in `libdd-data-pipeline` and `libdd-trace-stats`. The
  consumers are not cut out with them, so the v35 graph does not compile for
  wasm32 at all: `libdd-capabilities-impl`, `datadog-remote-config` and
  `libdd-telemetry` use the removed items unconditionally. v24 (ddtrace 3.x) had
  no wasm32 gating and built stock.
- Consequence: ddtrace 4.x does not build. Its `_native` module only ever builds
  `NativeCapabilities` (hyper), so the host-provided-HTTP path upstream added
  for browser wasm is not an option for it either.
- Workaround: `pkgs/lib/wasix-crate-patches/libdd-*` narrow every cutout to
  non-wasmer wasm32 (`not(wasm32)` becomes
  `any(not(wasm32), target_vendor = "wasmer")`, `wasm32` becomes
  `all(wasm32, not(target_vendor = "wasmer"))`) and give `threading` a
  `pthread_self` arm. Mechanical, so regenerate them on a libdatadog rev bump.
- Fix: upstream should gate on a capability or feature rather than
  `target_arch`, and gate the consumers the same way it gates the providers.
  wasix has threads and sockets, and the hyper stack builds and links there.

### `select()` with exceptfds returns ENOSYS; callers spin 🟢

- Symptom: wasix-libc returned ENOSYS whenever `select()` or `pselect()`
  received non-empty `exceptfds`. Rsync treated it as transient and spun before
  its first transfer.
- Fix: `sysroot/libc-select-exceptfds.patch` clears and ignores `exceptfds`,
  which is sufficient for defensive callers such as rsync. True exceptional-fd
  semantics still require runtime support. The rsync copy test passes; upstream
  the libc patch and drop it once merged.

### rsync copies files but hangs at exit: SIGUSR2 ignored for forked children 🟢

- Symptom: rsync copied every file but hung at exit because SIGUSR2 was ignored
  by its forked sender and generator. `proc_fork` did not propagate the guest
  signal callback, while libc's copied registration flag prevented the child
  from registering it again.
- Fix: `patches/wasmer-signal-inherit-on-fork.patch` makes `proc_fork` inherit
  and re-resolve the callback. `rsync -a` now copies and exits successfully.
  Upstream to wasmer and drop the patch once merged.

## Registry

### no version encoding for republishing a changed webc 🔴

Registry package versions are immutable tags on content hashes, and the webc
embeds neither the version nor `[package.metadata]`: `wasmer package build`
emits byte-identical webcs for `x`, `x+meta`, `x-pre`, and any
`package.metadata` contents (verified with kilyanni/crabsay), and publishing
`x+meta` over an existing `x` exits 0 without tagging anything (verified on
wasmer.wtf). Prereleases would tag as distinct versions but never resolve (see
below). So a changed webc at an unchanged upstream version cannot be
republished, and the `wasix-rel` recorded in `[package.metadata]` is
source-manifest plumbing only; a rel bump does not change the published artifact
at all yet. Needs a registry-side decision: treat build metadata as version
identity, or bless the CLI's `--bump` patch-bump convention (and ideally stop
stripping `package.metadata`). Wheels are unaffected (PEP 440 `+wasix.N`, own
index).

Also: `wasmer publish` retries a `permission denied` GraphQL failure
indefinitely (one attempt every ~2s until killed); a hard auth error should
abort. Hit with a wasmer.io token against wasmer.wtf; tokens are per-registry.

### a prerelease-only package never resolves 🔴

`wasmer run <owner>/<pkg>` with no version cannot reach a package whose only
published versions are prereleases, so `1.2.4-unstable.2026.7.6` for a VCS
snapshot is unusable today. This is client-side, not a registry decision: the
resolver fetches every version
(`lib/wasix/src/runtime/resolver/ backend_source.rs`, the
`getPackage { versions { ... } }` query, so not the API's `lastVersion`), an
absent version becomes `VersionReq::STAR`, and
`version_constraint.matches(&version)` filters locally. The `semver` crate
deliberately excludes prereleases from a comparator that names none, which is
cargo's rule, so `*` matches nothing here. `local_registry_source.rs` and
`in_memory_source.rs` filter the same way, so `--include-webc` trees are
affected too and the gap does not show up in local testing.

Fix in the resolver, matching pip (PEP 440 mandates the fallback when every
candidate is a prerelease) and npm (`latest` points at a prerelease on first
publish): when no version satisfies the constraint and every candidate is a
prerelease, take the highest prerelease. Packages that have any stable release
keep resolving to it, so `latest` never regresses to a prerelease once one
exists. That covers the case we need, since a package tracking a VCS snapshot
has no stable versions by construction.

Until then `<ver>-unstable-<date>` has no correct encoding: it needs a version
strictly between `<ver>` and the next patch, and semver's only mechanism for
that is a prerelease. Bare `0-unstable-<date>` is encodable as `0.0.YYYYMMDD`
(crabsay does this) since it has no stable release to sit above.

### upstream versions with more than three numeric components 🟡

Semver has three fields and pandoc's PVP `3.7.0.2` has four. Truncating collides
(`3.7.0.2` and `3.7.0.3` both land on `3.7.0`), and any fold that avoids the
collision has to cover the package's whole version history to stay monotone:
transforming only the 4-component releases puts `3.7.0.2` above `3.7.1`. That
makes it per-package knowledge, so `toSemver` now refuses and the package
declares a rule in `passthru.wasmer.version` (a function of the upstream
version, so it survives bumps). pandoc folds the PVP tail base-100, giving
`3.7.0.2` -> `3.7.2` and `3.7.1` -> `3.7.100`.

Nothing to fix upstream; noted because the next four-component package will hit
the throw and needs to know why truncating is not the answer.

### anybuild pins a python runtime our wheels cannot load 🟡

- Symptom: an anybuild app using our cp313 wheels fails to import native
  modules, for example `pydantic_core._pydantic_core`. The published
  `python/python@=3.13.5` runtime does not recognize the `-threads` extension
  suffix used by our wheels; abi3 modules still load.
- Consequence: anybuild cannot run apps containing interpreter-specific wheels
  from this repository with its pinned Python runtime.
- Workaround: the serve check substitutes our own interpreter through the
  vendored `ANYBUILD_WASMER_PACKAGE_<DEP>` knob plus `--include-webc`.
- Fix: republish `python/python` from a threads-enabled interpreter (this
  repo's), or point anybuild at the versioned interpreter package we publish.
