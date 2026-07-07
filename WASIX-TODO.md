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

### spawned commands and PATH 🟢

- Fixed in current wasmer: `posix_spawnp` and fork + `execvp` both resolve the
  child via the guest PATH, and the child's `argv[0]` arrives correctly
  (verified with minimal C programs).
  Older runtimes could not resolve by name, which is why git execs absolute
  baked paths; that approach still works and stays.
- The find suite's `-exec`/xargs tests stay `broken` regardless: the spawned
  tools (cat/echo) aren't on the guest PATH at all — the test harness forwards
  an env allowlist, not the host PATH — so there is nothing for resolution to
  find. That is a harness/environment gap, not this issue.

### `argv[0]` 🟢

- Correct on current wasmer for both directly-run and spawned programs
  (verified). Older runtimes passed `(null)`.

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

## Toolchain

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

### wasixcc hoists linker flags away from the inputs 🟡
- wasixcc buckets `-Wl,*`/`-Xlinker` args into `linker_args` (emitted before
  its own flags) and file inputs into `linker_inputs` (emitted at the end):
  any position-sensitive linker construct is destroyed. Notably
  `-Wl,--whole-archive foo.a -Wl,--no-whole-archive` puts both markers up
  front and the archive at the back, bracketing nothing (verified: zbar's
  dylib came out 633 bytes; pyarrow's libarrow_python.so silently lacked most
  arrow symbols and failed at import with `GOT.mem ... Missing export`,
  because `--unresolved-symbols=import-dynamic` defers underlinking to load).
- Workaround: link dylibs from loose objects instead of archives (zbar
  extracts with `$AR x`, pyarrow by-instance `$AR xN` since libarrow.a holds
  duplicate member names).
- Fix: keep link-stage tokens in one ordered list, as the clang driver does
  (`cxx-linking/src/compiler/flags.rs` `process_compiler_flags` splits them,
  `compiler.rs` `link_inputs` emits the buckets separately).

### `wasm-opt` corrupts autoconf feature detection 🟡 (not re-verified)

- A failing wasm-opt run on a throwaway conftest makes `configure`
  false-negative a feature (sqlite: "Cannot find libm functions").
- Workaround: `disableWasmOptInConfigureHook`, opt-in per package (sqlite,
  libzip).
- Fix: skip or tolerate wasm-opt during configure.

## Packages that don't cross-build

- **tzdata** 🟡: `localtime.c` needs getresuid/tzname/…, absent on WASIX.
  Dependents use build-platform tzdata (zoneinfo is platform-independent
  data): jq, python3.
- **libffi** 🟡: nixpkgs libffi has no wasm32-wasi port; the
  `wasix-org/libffi` fork adds one.
- **pcre2grep callout-fork** 🟡: uses fork();
  `--disable-pcre2grep-callout-fork` (the library is unaffected).

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
  cargo-wasix need no workaround. Python wheels pulling getrandom 0.3
  (bcrypt, pydantic-core) pin the `wasix-org/getrandom` fork; its backend
  adds a dependency on the `wasix` crate, which a vendor patch can't
  introduce (see `overlay/python-packages/lib/rust.nix`).
