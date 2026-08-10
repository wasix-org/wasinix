# WASIX quirks & issues

Runtime, libc, and toolchain issues hit while packaging: a reference when a
package breaks in a familiar way, and a worklist for upstream fixes.
Re-verified 2026-07-02 against wasmer 7.2.0, wasix-libc v2026-06-25.1,
binaryen 129; entries marked "not re-verified" are carried on trust.

Status: 🔴 needs upstream fix · 🟡 workaround in place · 🟢 fixed.

## Runtime / libc

### `fchdir` doesn't exist 🟡

- wasix-libc has no `fchdir` at all: not declared in the headers, no symbol in
  `libc.a` (verified: undeclared-function error, then undefined symbol with a
  manual declaration). There is also no general fd-to-path mechanism (only
  preopen names via `fd_prestat_dir_name`).
- Consequence: gnulib's `save_cwd` (open "." + fchdir to restore) can't work;
  its fallback made every gnulib CLI exit non-zero with ENOTDIR.
- Workaround: `find/package.nix` patches `gl/lib/save-cwd.c` to force
  getcwd + chdir.
- Fix: `__wasi_fchdir` in wasmer plus libc wiring. Fixes gnulib CLIs globally.

### `posix_spawn` fd passing 🟡

- Non-stdio fds are not inherited by the child even with FD_CLOEXEC cleared,
  and a dup2 file action onto the same fd (the POSIX idiom to clear CLOEXEC)
  is a no-op. Both diverge from POSIX. A dup2 action with a distinct target
  does inject the parent fd, and actions apply sequentially to the child
  table (verified with pipe-passing tests on wasmer 7.2.0).
- Consequence: anything passing pipes to a spawned child by fd number breaks
  (multiprocessing's resource tracker and spawn start method).
- Workaround: cpython's `multiprocessing-posix-spawn-wasi.patch` bounces each
  passed fd through a slot above all passed fds (`dup2 fd->tmp`,
  `dup2 tmp->fd`, `close tmp`; tmp starts at `max(128, max fd + 1)` so the
  slots never collide with the fds being placed).
- Fix: implement POSIX inheritance semantics for `proc_spawn` in wasmer:
  inherit non-CLOEXEC fds, honor same-fd dup2 as CLOEXEC clear.

### signals don't interrupt blocked pipe reads 🔴

- SIGTERM/SIGKILL to a process blocked in `read()` on a pipe neither kills it
  nor errors the read; a subsequent `waitpid` blocks forever. A child blocked
  in `sleep()` dies fine (verified with paired spawn/kill tests on wasmer
  7.2.0). The blocked read likely parks the instance in a host-side await
  that signal delivery never cancels.
- Consequence: `multiprocessing.Pool.terminate()` (and the `with Pool(...)`
  context manager, which calls it) hangs: idle workers sit blocked in queue
  reads and can't be killed. `pool.close(); pool.join()` works because
  sentinels wake the workers first. Same risk for any subprocess kill/timeout
  pattern where the child blocks on fd reads. Also why hf-xet's SIGINT handler
  is a no-op on wasix (hf-xet-wasi-sigint.patch): a native handler would be
  inert until delivery is fixed, and CPython owns Ctrl-C at the Python boundary.
- Fix: wasmer's signal delivery must cancel in-flight blocking syscalls
  (EINTR or instance termination).

### spawned commands and PATH 🟢

- Fixed in current wasmer: `posix_spawnp` and fork + `execvp` both resolve the
  child via the guest PATH, and the child's `argv[0]` arrives correctly
  (verified with minimal C programs).
  Older runtimes could not resolve by name, which is why git execs absolute
  baked paths; that approach still works and stays.
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
  (verified under wasmer; `overlay/python-packages/psutil/tests/basic.nix`).
  `os.sched_getaffinity` does not answer either.
- Consequence: joblib/loky's `cpu_count(only_physical_cores=True)` falls through
  both to that `psutil.Process()` and propagates the error, since its `try` only
  catches `ImportError`. scikit-learn's `_openmp_effective_n_threads()` calls it
  whenever `OMP_NUM_THREADS` is unset, so every OpenMP-parallel estimator needs
  that variable in the environment on wasix; with it set sklearn takes the
  `omp_get_max_threads()` branch and never reaches psutil. Both directions are
  pinned by `overlay/python-packages/scikit-learn/tests/basic.nix`.
- Fix: answer self-inspection in wasmer (pid 1 exists, so `Process()` should
  resolve it), which also gets loky off the fallback path.

### exec'ing a symlinked helper in a webc fails ENOEXEC 🟢

- `WebcVolumeFileSystem::open()` read raw (non-following) metadata, so a symlink
  resolved to `Err(NotAFile)`. Exec'ing a symlinked binary
  (git's `libexec/git-core/git-upload-pack -> ../../bin/git.wasm`, and the other
  git helpers) therefore failed with ENOEXEC ("cannot execute binary file"),
  breaking every git transport test (clone/fetch/push over local/http/https/net)
  while the same tree on a real fs works.
- Fixed: `patches/wasmer-webc-follow-symlinks.patch` resolves symlinks (relative
  targets against the link's parent, bounded loop) before opening, matching
  real-fs semantics. Verified: `checks.git` (all transport tests) passes with it.
  Vendored from python-pkgs; upstream to wasmerio/wasmer and drop once merged.

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

### `isatty` returns true for redirected stdout 🟡

- `isatty(1)` is 1 even with stdout redirected (verified). Tools colorize into
  files (jq emits ANSI into `>file`).
- Workaround: tests strip ANSI (`testLib.normalizers.stripAnsi`).
- Fix: report non-TTY for regular files/pipes.

### no default `TERM` 🔴

- wasmer starts processes with `TERM` unset (verified); terminal programs
  degrade. Fix: a runtime default.

### `getifaddrs`/`freeifaddrs` misnamed in wasix-libc 🟡

- wasix-libc's `ifaddrs.h` declares the standard `getifaddrs`/`freeifaddrs`,
  but `libc.a` only defines `getif_addrs`/`freeif_addrs` (verified with nm;
  python3.wasm exports only the underscored names). Callers compile, then die
  with undefined symbols at link or dylib import. `if_indextoname` and
  `if_nametoindex` are declared in `net/if.h` but not defined at all.
- Workaround: libuv's `libuv-0013-wasix-ifaddrs-names-no-if_index.patch` maps
  the names and stubs the `if_*` lookups.
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
  lowers to and the libc build omits, counts the mask bits). The
  duckdb/opencv `__wasi__` guard patches are now redundant and removed. Upstream
  this stub file into wasix-libc.

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
- Workaround: `overlay/python-packages/scipy.nix` drops the `_test_internal`
  module (test-only, `install_tag 'tests'`, not imported by normal scipy);
  `overlay/packages/hdf5/patches/hdf5-wasi-fenv.patch` guards the fe\* dance for
  `__wasi__` (nothing to mask on wasm).
- Fix: define the missing rounding-mode and exception-flag macros in wasix-libc
  (distinct int values), have `fesetround` return nonzero for anything but
  `FE_TONEAREST`, and keep `feclearexcept`/`fetestexcept` as no-ops, matching
  glibc/musl on FPUs without directed rounding or exceptions. Downstream then
  compiles unchanged.

### POSIX advisory record locking is not implemented 🟡

- WASIX supports threads and multiple processes through `thread_spawn`,
  `proc_fork`, and `proc_spawn*`, but the Wasmer WASIX ABI has no operation for
  coordinating POSIX record locks between them.
- The vendored wasix-libc patch exposes `F_GETLK`/`F_SETLK`/`F_SETLKW`, the lock
  types, and `struct flock` so feature-detected consumers compile. The operations
  return `ENOSYS`; reporting success would falsely claim exclusion and risk
  cross-process corruption.
- Workaround: h5py's runtime test sets `HDF5_USE_FILE_LOCKING=FALSE`; DuckDB skips
  its lock calls on WASI in `duckdb-wasi-no-file-lock.patch`.
- Blocks the `fs2` crate, whose whole API is locking, and any crate reaching the
  filesystem through it. tantivy takes its index lock via `fs2::FileExt`, so the
  overlay registry cannot serve it from a floor patch: a port has to replace the
  mmap directory backend, as the wasix-org 0.18 fork does, rather than widen a
  cfg gate.
- Upstream fix: add record-lock operations and shared per-file lock state to
  Wasmer's WASIX filesystem ABI, then implement the fcntl commands in wasix-libc
  and remove the package workarounds.

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
- Workaround: `overlay/packages/onnxruntime/patches/onnxruntime-wasi-no-dladdr.patch`
  guards the `dladdr` path on `__wasi__` (as onnxruntime already does for AIX),
  taking the non-`dladdr` fallback. Fine for a static single-EP build that loads
  no provider `.so`.
- Fix: implement `dladdr` in wasix's dyld (fill `Dl_info` from the module table),
  or at least export a weak stub returning 0 so consumers take their own
  fallback instead of failing to import.

### `dlfcn.h` ships for `off` but not the non-PIC EH sysroots 🟡

- `Makefile-eh` omits the header when PIC is off (`MUSL_OMIT_HEADERS +=
"dlfcn.h"` under `ifeq ($(PIC), no)`), while the plain `Makefile` the `off`
  profile uses has no such rule. So `sysroot` (off), `sysroot-ehpic` and
  `sysroot-exnref-ehpic` carry `dlfcn.h`; `sysroot-eh` and `sysroot-exnref-eh`
  do not (verified against the built sysroots).
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

## Toolchain

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

- A maturin/pyo3 wheel whose closure pulls libc++ exception code (or any legacy
  Wasm-EH) loads with `Validate("legacy_exceptions feature required for try
instruction")` under the pinned wasmer (7.2.0), which only accepts the new
  (`try_table`/exnref) encoding. Hit on `tokenizers` (esaxx-rs C++ throws, which
  links libc++'s `std::runtime_error`/`std::logic_error` ctors).
- Root cause (disassembled `tokenizers.abi3.so` at the failing offset 0x66b5c1):
  the legacy `try` sits in libc++'s own compiled exception helpers, NOT
  compiler-rt SjLj. The rust toolchain's std targets link the **legacy-EH**
  sysroots (`toolchain/rust/toolchain.nix`: `wasm32-wasmer-wasi` ->
  `wasixSysrootEh`, `wasm32-wasmer-wasi-dl` -> `wasixSysrootEhpic`), so an
  extension module (built on the `-dl`/PIC target) links the ehpic `libc++.a`,
  whose `stdexcept.cpp.o` carries 6 legacy `try` (verified: the exnref-ehpic
  `libc++.a` has 0 legacy / 15 `try_table`; the ehpic one has 6 legacy / 0).
  This is why the legacy `try` was invariant to per-crate `--wasm-use-legacy-eh`
  cc flags (those only reach the wheel's OWN C/C++, which came out `try_table`)
  and to the python profile switch (the rust `-dl` sysroot is fixed regardless).
- Why CLIs don't hit it: cargo-wasix runs `wasm-opt --translate-to-exnref` on
  every `.wasm` it emits (lib.rs `run_wasm_opt`), converting all legacy EH to
  exnref. A maturin cdylib is a `.so`, so that pass (keyed on the `.wasm`
  extension) never runs on it. Pure-rust wheels (jiter, pydantic-core) import
  fine because panic=abort leaves no EH to translate.
- Workaround (in place): a setup hook on the shared `maturinBuildHook`
  (`set/rust-platform.nix`, `exnrefTranslateHook`) re-applies
  `wasm-opt --translate-to-exnref` to every wheel `.so` in `fixupOutputHooks`,
  so EVERY maturin wheel gets the same pass cargo-wasix gives CLIs, not just
  tokenizers. Same `toolchain.binaryen` cargo-wasix uses; a no-op on wheels with no
  legacy EH (verified: tokenizers -> 0 legacy `try`, wasmer 7.2.0 validates +
  imports; jiter/pydantic-core unaffected). Unblocks tokenizers -> litellm.
- Why not routed through cargo-wasix: maturin drives `cargo rustc` and parses
  cargo's artifact JSON itself; cargo-wasix also drives+consumes that stream and
  has no `rustc` subcommand, so putting it in the middle hides the artifact from
  maturin. The hook is the maturin analogue of cargo-wasix's CLI pass.
- Proper fix (upstream): (a) point the rust std targets at the **exnref**
  sysroots (`variants.exnrefEh`/`exnrefEhpic`) so linked libc++ is already
  `try_table`, though that rebuilds std, and the wheels' own rust EH still needs the
  translate pass unless panic=abort; or (b) teach cargo-wasix to post-process
  cdylib artifacts (e.g. a standalone `opt` subcommand the hook calls), moving
  the pass's ownership back into cargo-wasix. Then drop `exnrefTranslateHook`.
- Not covered: setuptools-rust wheels (tiktoken) don't use `maturinBuildHook`;
  they're fine today (pure Rust, no legacy EH) but a C++-using one would need the
  same hook wired into that path.

### asyncify can't process Wasm-EH instructions 🟡

- `wasm-opt --asyncify` aborts ("unexpected expr type", Flatten.cpp) on
  modules containing EH instructions. Under the EH profiles that means C++
  exceptions or anything using setjmp/longjmp (lowered to Wasm-EH SjLj):
  verified with a C++ binary, and reproduced by git's clar unit-tests binary
  (clar uses setjmp). Plain C without setjmp asyncifies fine regardless of
  feature flags.
- Workaround: fork-using C programs (git, findutils) set
  `WASIXCC_WASM_OPT_FLAGS=--asyncify:-O2`, so wasixcc's link-time wasm-opt
  applies the pass in the EH profiles like it does on its own in the off
  profile. git additionally skips building its test binaries
  (`TEST_PROGRAMS=`, `CLAR_TEST_PROG=`), which contain setjmp and can never
  run in a cross build.
- Fix: binaryen asyncify support for EH; upstream the wasixcc setting.

### `wasm-opt` corrupts autoconf/cmake feature detection 🟡

- A failing wasm-opt run on a throwaway conftest makes `configure`
  false-negative a feature (sqlite: "Cannot find libm functions").
- Root cause (re-verified 2026-07-13, thrift at eh): function-exists probes
  declare wrong signatures (`char strerror_r();`); wasm-ld silently links
  that into invalid wasm, and wasm-opt fatals parsing it. Only eh is hit:
  wasixcc always appends `--emit-exnref` there, so wasm-opt runs even for
  -O0 probes; the other profiles skip it (no passes at -O0).
- Workaround: `disableWasmOptInConfigureHook`, opt-in per package (sqlite,
  libzip, thrift).
- Fix: wasm-ld should reject signature-mismatched direct calls (LLVM fork),
  or wasixcc's autoconf workarounds mode skips post-link wasm-opt.

### non-default python splices a wasm `pyproject-build` in nativeBuildInputs 🟡

- The default python is py314. A package that runs `pyproject-build` directly
  (from `build` in nativeBuildInputs, as the C++ onnx does in preBuild, rather
  than via `pypaBuildHook`) builds fine on py314 but on py313 (non-default) `build`
  splices to the wasm target: its `.pyproject-build-wrapped` is a python script,
  and bash runs it and chokes on the `lambda` in the site-init line. The
  pythonOnBuildForHost native `build` exists; the nativeBuildInputs splice just
  does not pick it in the non-default python's package set.
- Consequence: the C++ onnx re-instantiated in the python313 set fails; and it is
  re-instantiated per interpreter because the python onnx wheel pulls `onnx`
  (C++) through its own set. (An earlier abi3-dist `.override` that forced the
  py314 C++ onnx worked for py314 but dragged its py314 python + protobuf onto
  the py313 wheel's PYTHONPATH, which shadowed py313's build tools, so the
  `packaging`/`installer` failures seen then were that pollution, not a real
  py313 provisioning gap.)
- Workaround: `overlay/python-packages/onnx.nix` repackages only the abi3 wheel
  FILE from the top-level (native) py314 C++ onnx and drops the onnx package from
  build/propagated inputs, so no per-interpreter C++ onnx is built and no py314
  python leaks. Both py313 and py314 wheels import green.
- Fix: make the non-default python's package set splice `build` (and peer pypa
  tools) to `pythonOnBuildForHost` in nativeBuildInputs, matching the default, so
  a package that must genuinely build a wheel on py313 works.

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

### scipy calls the flang reference BLAS/LAPACK without F77 hidden CHARACTER lengths 🟢

- Reference BLAS/LAPACK routines take `CHARACTER*1` flags (`TRANSA`, `UPLO`, …).
  flang emits them with the standard F77 hidden-string-length ABI: each character
  argument adds a trailing `size_t` length parameter (i32 on wasm32), appended
  after all explicit args. Much of scipy's C/Cython glue declares the Fortran
  symbols WITHOUT those hidden lengths, calling e.g. `dgemm_(char*, char*,
int*, …)` with 13 args, while flang's `dgemm_` is a 15-arg wasm function. On x86
  harmless (the extra slots are ignored), but wasm `call_indirect` is strictly
  typed: wasm-ld emits a trapping stub and the call dies at runtime
  (`signature_mismatch:dgemm_`). f2py's wrappers (`_fblas`/`_flapack`) already
  pass the hidden lengths, so the f2py path (`scipy.linalg.solve/lstsq/eig`, so
  `LinearRegression`) is fine; 15-arg is the correct target everywhere. Never an
  OpenMP issue (libomp runs; the trap is in the BLAS call).
- Fixed: the `cython_blas`/`cython_lapack` path. `scipy-cython-blas-fortran-charlen.patch`
  (in `scipy.nix`) patches scipy's `_generate_pyx.py` so the generated
  `_fortran_<name>` externs and calls carry the hidden lengths (value 1: every
  wrapped char arg is CHARACTER\*1 and LSAME ignores the length; ilaenv/xerbla are
  not wrapped). Only the internal Fortran calls change; the public `cdef` wrapper
  signatures are untouched, so downstream `cython_blas`/`cython_lapack` consumers
  stay ABI-compatible. Verified by scikit-learn's fit check (direct
  `cython_blas._test_dgemm` + `KMeans.fit`). This is what scikit-learn /
  statsmodels reach, so the downstream story is green.
- Also fixed: scipy's OWN hand-C/C++ modules (which declare the Fortran symbols
  themselves and called 13-arg) via `scipy-hand-c-blas-fortran-charlen.patch`,
  covering `_lbfgsb`/`_slsqplib` (optimize.minimize L-BFGS-B/SLSQP),
  `_odepack`/`_vode` (integrate.odeint/ode), `_batched_linalg`,
  `_internal_matfuncs` (expm/sqrtm), and the three vendored solvers that ship
  their own BLAS decls: `_propack`, arpack (arnaud), and SuperLU. 10 header files.
  Same shape as the cython patch, plus one extra class: `?getrf`/`?getri` are
  declared CBLAS_INT-returning but flang's subroutines return void (a return-type
  mismatch). Technique: bind the true flang symbol to a private name via an
  `__asm__` label (with the hidden `size_t` lengths), define a DISTINCT-named
  `static inline` wrapper that appends `1` per char arg, and `#(re)define` the
  mangled name to the wrapper. The distinct name matters: a wrapper reusing the
  true symbol name makes the asm label bind the call back into the wrapper
  (verified self-recursion under wasm-ld). All gated on `__wasi__`/`__wasm__`;
  lengths/void-returns verified against the reference lib arities. Warnings
  426 -> 1. Verified by `scipy/tests/basic.nix` under wasmer (optimize L-BFGS-B/
  SLSQP, integrate odeint/LSODA, expm/sqrtm, batched svd/lu/qr/cholesky/eig,
  PROPACK svds).
- Left: `chla_transtype_` in `cython_lapack` (the last warning), a
  CHARACTER-returning helper with a distinct hidden-result-buffer ABI that scipy
  never calls directly.
- Upstream: a latent scipy portability bug where the glue relies on a lax C ABI that
  strict targets (wasm) reject. Upstream scipy could pass the hidden lengths
  unconditionally, as its own f2py wrappers already do.

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
  misleading message. rapidfuzz's LLVM-style atomic check fatals with "No
  native support for std::atomic<int>" though the probes compile fine with
  scanning off (all HAVE*CXX_ATOMICS*\* pass). duckdb and pyzmq have no such
  probe and build with scanning on.
- Workaround: a set-wide setup hook in `set/stdenv.nix` defaults
  `-DCMAKE_CXX_SCAN_FOR_MODULES=OFF` for every cmake build (harmless where cmake
  never scans; no per-package opt-out needed).
- Fix: make `clang-scan-deps` see the wasix sysroot/target on try-compiles (wire
  it through the shim, or export the flags cmake forwards to it) so scanning
  actually works, then drop the hook. Scanning is off because it misreports
  probes, not because C++20 modules are unwanted.

## Packages that don't cross-build

- **tzdata** 🟡: `localtime.c` needs getresuid/tzname/…, absent on WASIX.
  Dependents use build-platform tzdata (zoneinfo is platform-independent
  data): jq, python3.
- **libffi** 🟡: nixpkgs libffi has no wasm32-wasi port; the
  `wasix-org/libffi` fork adds one.
- **pcre2grep callout-fork** 🟡: uses fork();
  `--disable-pcre2grep-callout-fork` (the library is unaffected).
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
- **boost** 🟡: Boost.Build (b2) rejects `architecture=wasm` ("not a known
  value of feature <architecture>"), so nixpkgs' cross boost never configures.
  Its only wasix consumer so far is scipy, which needs the header-only
  boost.math; `python-packages/scipy.nix` uses the build-host boost's headers
  (`BOOST_INCLUDEDIR`/`BOOST_LIBRARYDIR`, both required by meson's boost
  detection) instead of cross-building. Fix (for a real wasix boost): teach b2 a
  `wasm`/`wasm32` architecture value (or map it to a no-op), then build
  header-only or the subset that compiles.
- **qhull** (not broken, packaging quirk) 🟢: the static-only wasix build makes
  `libqhullstatic_r.a`, but qhull_r.pc and consumers link `-lqhull_r` (the
  shared-build name); `packages/qhull.nix` aliases the static archives under the
  `-lqhull_r`/`-lqhull` names.

## Rust

### library/Cargo.lock pins libc 0.2.183 from two sources 🟡

- std depends on the libc fork via a direct git dependency while the other
  library crates (dlmalloc, panic_unwind, std_detect, test, unwind) stay on
  registry libc. Since the fork's port matches the version the workspace
  resolves (both 0.2.183 as of v2026-07-07.2+rust-1.96), the lockfile carries
  the same name+version from two sources: importCargoLock keys vendor dirs by
  name+version, the second symlink collides, and the toolchain cannot be
  vendored. Wasix std also mixes crates built against two different libcs.
- Workaround: `toolchain/rust/libc-patch-crates-io.patch` routes crates-io
  libc to the fork via `[patch.crates-io]` (applied in postPatch);
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
  (bcrypt, pydantic-core) still pin the `wasix-org/getrandom` fork; its
  backend adds a dependency on the `wasix` crate, which a vendor patch can't
  introduce (see `overlay/python-packages/lib/rust.nix`). The fork-free vendor
  patch below is preferred and has replaced the fork for jiter.

### getrandom 0.3/0.4 fixed fork-free by selecting the p1 backend 🟡

- Both getrandom 0.3.4 and 0.4.3 ship a `wasi_p1` backend that is a raw
  `extern "C" random_get` from `wasi_snapshot_preview1` (which wasix libc
  provides) with **no crate dependency**, but their `backends.rs` only picks
  it under `#[cfg(target_env = "p1")]`, and our target's env isn't p1, so they
  fall to the component-model backend and `compile_error!` ("Unknown version of
  WASI"). No fork or `wasix` crate is needed; just reroute the selection.
- Workaround: `lib/vendor-getrandom-wasi.nix` (helper
  `rust.patchVendoredGetrandomWasi`) patches vendored getrandom 0.3/0.4
  `backends.rs` to use `wasi_p1` for anything that isn't p2/p3, and refreshes
  the checksum. Used by `jiter.nix`/`uuid-utils.nix`/`fastuuid.nix` with no
  `[patch.crates-io]` fork and no shipped lock. This is simpler than the
  getrandom-0.3 fork above and should replace it for bcrypt/pydantic-core too.
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
  `libdd-telemetry` use the removed items unconditionally. v24 (ddtrace 3.x)
  had no wasm32 gating and built stock.
- Consequence: ddtrace 4.x does not build. Its `_native` module only ever
  builds `NativeCapabilities` (hyper), so the host-provided-HTTP path upstream
  added for browser wasm is not an option for it either.
- Workaround: `pkgs/lib/wasix-crate-patches/libdd-*` narrow every cutout to
  non-wasmer wasm32 (`not(wasm32)` becomes
  `any(not(wasm32), target_vendor = "wasmer")`, `wasm32` becomes
  `all(wasm32, not(target_vendor = "wasmer"))`) and give `threading` a
  `pthread_self` arm. Mechanical, so regenerate them on a libdatadog rev bump.
- Fix: upstream should gate on a capability or feature rather than
  `target_arch`, and gate the consumers the same way it gates the providers.
  wasix has threads and sockets, and the hyper stack builds and links there.

### `select()` with exceptfds returns ENOSYS; callers spin 🟢

- wasix-libc's `select()`/`pselect()` returned `-1`/`ENOSYS` (errno 52) whenever
  `exceptfds` was non-empty. The bug was purely in libc, not the runtime:
  `libc-bottom-half/cloudlibc/src/libc/sys/select/pselect.c` hardcoded
  `if (errorfds && errorfds->__nfds > 0) { errno = ENOSYS; return -1; }` BEFORE
  it built any subscriptions or called `__wasi_poll_oneoff` (that is why the WASI
  trace showed no `poll_oneoff`). `poll_oneoff` genuinely has no exceptional-
  condition event type, so TRUE exceptfds semantics (TCP OOB) would need runtime
  support, but callers like rsync only pass exceptfds defensively.
- This is what stalled `rsync`'s transfer (NOT a fork/pipe IPC deadlock, which
  all works). rsync's one IO multiplexer `perform_io()` (io.c) always passes an
  exceptfds set (`FD_SET(iobuf.in_fd, &e_fds)`), and its error handling only
  special-cases `EBADF`; the ENOSYS was treated as transient, so it zeroed the
  fd sets and looped into a pure-compute 100% CPU spin with ZERO syscalls (verified
  via strace + WASI trace), hanging on the first IO (the version exchange).
- Fixed: `sysroot/libc-select-exceptfds.patch` makes `pselect()` ignore
  exceptfds (and `FD_ZERO` it) instead of failing. Verified: `rsync -rv src/
dst/` now transfers all files correctly (`diff -rq src dst` clean, incl. nested
  dirs). Fixes every select+exceptfds caller, not just rsync. Upstream this to
  wasix-org/wasix-libc and drop the patch once merged.

### rsync copies files but hangs at exit: SIGUSR2 ignored for forked children 🟢

- With the select fix, rsync completes the whole transfer (files land correctly)
  but never exits. Root cause: rsync's shutdown is signal-driven, so the sender /
  generator processes only terminate when they receive SIGUSR2 (`main.c`
  `sigusr2_handler` -> `_exit(0)`), and the receiver does `kill(pid, SIGUSR2)`
  then `wait_process`. Under wasix the runtime logs `state::env: Signal ignored
pid=3 sig=Sigusr2` for the forked children, so nobody exits and all three
  processes (pid1 -> waits pid2 -> waits pid3) spin in a `proc_join` poll-loop
  (verified: 1073 `proc_join` + a 21ms-timeout `poll_oneoff` clock loop, no
  `proc_exit`).
- Precise mechanism (two layers, both in the wasix-org forks):
  - wasmer `lib/wasix/src/state/env.rs` `process_signals_and_exit` only invokes
    the guest handler when `inner.signal_set` is true; otherwise a non-fatal
    signal is "ignored". `signal_set`/`signal` (the `__wasm_signal` export) are
    set ONLY by the `callback_signal` syscall (`syscalls/wasix/callback_signal.rs`).
    `WasiEnv::fork()` builds the child with `inner: Default::default()`
    (`signal_set=false`, `signal=None`) and `proc_fork` never re-propagates them
    so a forked child's instance has no signal callback.
  - wasix-libc `libc-top-half/musl/src/signal/sigaction.c` calls
    `__wasi_callback_signal("__wasm_signal")` exactly once, guarded by the static
    `__eintr_callback_registered` (CAS 0->1). fork copies that static into the
    child's memory as already-set, so the child's libc never re-registers. rsync
    forks via the raw `__wasi_proc_fork` shim (no libc `fork()` wrapper), so
    there is no atfork hook to reset it either.
- Fixed: `patches/wasmer-signal-inherit-on-fork.patch` makes `proc_fork` inherit
  the signal disposition. It captures the parent's `signal_set` before forking, and
  in the child (proc_fork.rs `run`, once the instance is live) re-resolves
  `__wasm_signal` and sets `inner.signal`/`inner.signal_set` when the parent had
  it. Matches POSIX (fork inherits handlers); fixes every fork+signal program.
  Layered onto the wasmer input via the flake's `overrideAttrs` patch list.
  Verified: under the patched wasmer `rsync -a src/ dst/` exits 0 (was 124/hang)
  with files copied and the final stats summary printed; stock wasmer still hangs
  (control). Upstream to wasmerio/wasmer and drop the patch once merged.

## Registry

### no version encoding for republishing a changed webc 🔴

Registry package versions are immutable tags on content hashes, and the webc
embeds neither the version nor `[package.metadata]`: `wasmer package build`
emits byte-identical webcs for `x`, `x+meta`, `x-pre`, and any
`package.metadata` contents (verified with kilyanni/crabsay), and publishing
`x+meta` over an existing `x` exits 0 without tagging anything (verified on
wasmer.wtf). Prereleases would tag as distinct versions but never resolve
(see below). So a changed webc at an unchanged upstream version cannot be
republished, and the `wasix-rel` recorded in `[package.metadata]` is
source-manifest plumbing only; a rel bump does not change the published
artifact at all yet. Needs a registry-side decision: treat build metadata as
version identity, or bless the CLI's `--bump` patch-bump convention (and
ideally stop stripping `package.metadata`). Wheels are unaffected (PEP 440
`+wasix.N`, own index).

Also: `wasmer publish` retries a `permission denied` GraphQL failure
indefinitely (one attempt every ~2s until killed); a hard auth error should
abort. Hit with a wasmer.io token against wasmer.wtf; tokens are
per-registry.

### a prerelease-only package never resolves 🔴

`wasmer run <owner>/<pkg>` with no version cannot reach a package whose only
published versions are prereleases, so `1.2.4-unstable.2026.7.6` for a VCS
snapshot is unusable today. This is client-side, not a registry decision: the
resolver fetches every version (`lib/wasix/src/runtime/resolver/
backend_source.rs`, the `getPackage { versions { ... } }` query, so not the
API's `lastVersion`), an absent version becomes `VersionReq::STAR`, and
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

Semver has three fields and pandoc's PVP `3.7.0.2` has four. Truncating
collides (`3.7.0.2` and `3.7.0.3` both land on `3.7.0`), and any fold that
avoids the collision has to cover the package's whole version history to stay
monotone: transforming only the 4-component releases puts `3.7.0.2` above
`3.7.1`. That makes it per-package knowledge, so `toSemver` now refuses and
the package declares a rule in `passthru.wasmer.version` (a function of the
upstream version, so it survives bumps). pandoc folds the PVP tail base-100,
giving `3.7.0.2` -> `3.7.2` and `3.7.1` -> `3.7.100`.

Nothing to fix upstream; noted because the next four-component package will
hit the throw and needs to know why truncating is not the answer.
