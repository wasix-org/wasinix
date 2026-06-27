# WASIX TODO — quirks & issues

A catalog of WASIX/Wasmer runtime, libc, and toolchain quirks hit while packaging.
Two uses: **reference** when a package breaks in a familiar way, and a **worklist**
to go through, reproduce minimally, and file upstream (Wasmer / wasix-libc / binaryen).

Each entry: symptom · where seen / how to repro · workaround in this repo · the real
fix · status.

Status legend: 🔴 needs upstream fix · 🟡 packaging workaround in place · 🟢 fixed upstream.

---

## Runtime / libc

### `fchdir` is broken 🟡→🔴
- **Symptom:** any gnulib-based CLI exits non-zero with `Failed to restore initial
  working directory: Not a directory` (ENOTDIR). Output is correct, but the exit
  code is 1.
- **Cause:** wasix has native `chdir` (`__wasi_chdir`) + `getcwd` (`__wasi_getcwd`)
  but **no `__wasi_fchdir`**, and musl's raw `SYS_fchdir` isn't wired — it errors.
  There's no general fd→path either (only preopen names via `fd_prestat_dir_name`).
  gnulib's `save_cwd` does `open(".")` + `fchdir` to restore → fails.
- **Repro:** `find <dir>` under wasmer; check `$?`. Minimal: C program `open(".")`
  then `fchdir(fd)`.
- **Workaround:** `find/package.nix` patches `gl/lib/save-cwd.c` (`cwd->desc = -1`)
  to force `getcwd`+`chdir`.
- **Fix:** add `__wasi_fchdir` to the Wasmer runtime + wire `wasix-libc/.../fchdir.c`
  → it. Fixes every gnulib CLI globally, not per-package.

### Spawned commands aren't PATH-resolvable 🔴
- **Symptom:** `find -exec cat …` / `xargs echo …` fail with `cat: No such file or
  directory`, though the fork+exec itself works. (find swallows it → exit 0; xargs
  propagates → non-zero.)
- **Cause:** a wasm process under wasmer can't resolve a sibling/external command by
  name in the guest PATH. git only works because it execs **absolute** baked paths
  (`${bash}/bin/bash.wasm`) + `autoSelfMount`, never a PATH lookup.
- **Repro:** `printf 'x\n' | xargs echo` under wasmer.
- **Fix:** spawned-command/PATH resolution for wasm processes (Wasmer side).

### `argv[0]` is wrong 🔴
- **Symptom:** errors prefixed `(null): …`; tools that branch on `argv[0]` (busybox
  multi-call style) misbehave; needs custom fixups.
- **Seen:** every wasix process error line, e.g. `(null): cat: No such file…`.
- **Fix:** populate `argv[0]` correctly in the WASIX process model.

### `fork()` is hidden under Wasm-EH 🟡
- **Symptom:** `call to undeclared function 'fork'` when compiling in the EH
  profiles; the symbol is also absent from `libc.a`.
- **Cause:** the sysroot hides `fork`'s declaration when
  `__wasm_exception_handling__` is defined.
- **Workaround:** git's `wasix-compat/` shim — a `unistd.h` declaring `fork` + a
  `proc.c` implementing it via `__wasi_proc_fork`; reused by findutils. fork needs
  **asyncify** at runtime.
- **Fix:** decide whether `fork` should be declared/available under EH; if so, expose
  it from the sysroot so the shim isn't needed.

### `isatty` returns true for a redirected stdout 🟡
- **Symptom:** programs that colorize/format only on a TTY do so even when piped to a
  file — e.g. jq emits ANSI color when stdout is `>file`.
- **Repro:** `echo '[1]' | jq add > out` under wasmer → `out` has `\e[…m` codes.
- **Workaround:** tests strip ANSI (`testLib.normalizers.stripAnsi`).
- **Fix:** `isatty`/`fd_filestat` should report non-TTY for regular files/pipes.

### TERM env fallback (pre-existing) 🔴
- wasmer should set a default `TERM` fallback so terminal programs/tools work better.

## Toolchain (wasixcc / binaryen / cross-build)

### `wasm-opt` corrupts autoconf feature detection 🟡
- **Symptom:** `configure` false-negatives a feature (e.g. sqlite: "Cannot find libm
  functions") because the wasm-opt pass over a throwaway conftest fails.
- **Workaround:** `disableWasmOptInConfigureHook` (overlay) — opt-in, on the few
  packages whose conftests trip it (sqlite, libzip).
- **Fix:** wasm-opt shouldn't fail (or shouldn't run) on trivial conftests; or the
  toolchain should skip it during `configure`.

### asyncify + Wasm-EH abort in binaryen 🟡
- **Symptom:** `wasm-opt --asyncify … --enable-exception-handling` aborts with
  "unexpected expr type" on EH binaries (e.g. git's build-time unit-tests).
- **Workaround:** the standalone asyncify pass omits `--enable-eh` (targets only
  shipped binaries) — git, findutils.
- **Fix:** binaryen asyncify + EH interop.

## Packages that don't cross-build for wasix

### `tzdata` 🟡
- **Symptom:** `localtime.c` uses `getresuid`/`getresgid`/`tzname`/`timezone`/
  `daylight` — absent on WASIX.
- **Workaround:** point dependents at the **build-platform** tzdata (zoneinfo is
  platform-independent data) — see `jq`.
- **Fix:** port tzdata, or provide the missing libc symbols.

### `libffi` 🟡
- nixpkgs `libffi` won't build for wasm; wasix uses the `wasix-org/libffi` fork.

### `pcre2grep` callout-fork 🟡
- pcre2grep's callout-fork uses `fork()`; build with
  `--disable-pcre2grep-callout-fork` (libpcre2 itself is fine) — see `pcre2`.

## Rust

### Rust programs exited 70 in std init — our toolchain built on the stable channel 🟢
- **Symptom:** every Rust wasm (`sd`, `crabsay`, any) exited 70 with no output under
  `wasmer run`, before `main`. Not a wasm-feature, runtime, cargo-wasix, or linker
  problem (all chased and ruled out) — and **not** wasi-libc's preopen `malloc` (an
  early wrong theory): the trace stopping at `fd_prestat_get` is a *symptom* of the
  real cause below, not a libc allocator-ordering bug.
- **Root cause:** rustc emits `--max-memory=4294967296` (4 GiB / 65536 pages) for a
  *shared* (threaded) wasm memory **only off the stable channel** — it's gated behind
  unstable wasm support. Our `wasix-rust-toolchain.nix` forced `--release-channel=stable`
  (upstream's `config.toml.wasix-template` sets no channel → non-stable), so rustc
  dropped the flag and the shared memory came out `max == initial` (non-growable). With
  no room to grow, the first heap allocation in std startup traps → `_Exit(70)`. The C
  wasm is unaffected because wasixcc passes `--max-memory` itself.
- **Diagnosis:** same toolchain, `RUSTC_BOOTSTRAP=1 rustc … --print link-args` shows
  `--max-memory` appear; plain stable shows only `--shared-memory`. Memory decl via
  `wasm-tools print | grep memory`: `(memory N N shared)` broken vs `(memory N 65536
  shared)` fixed. cargo-wasix's prebuilt path always worked because its toolchain is
  non-stable and so emits the flag natively.
- **Fix:** build on `--release-channel=nightly` (the wasix target genuinely needs
  rustc's unstable wasm support). No per-package flag — rustc emits `--max-memory`
  itself; `mk-wasix-rust-platform.nix` needs nothing for it.

### getrandom doesn't recognise the target 🟡
- getrandom 0.3 → "Unknown version of WASI" on `wasm32-wasmer-wasi`. Set
  `CARGO_TARGET_<triple>_RUSTFLAGS = --cfg getrandom_backend="wasi_p1"` (done globally
  in `mk-wasix-rust-platform.nix`) so every getrandom-using crate compiles.

### buildRustPackage wrapper had to learn nixpkgs idioms 🟢
- To consume real nixpkgs Rust packages (`prev.<pkg>.override { rustPlatform = … }`):
  the wrapper must accept the `finalAttrs:` function form (not just an attrset), and
  `CC_<target>` env keys must use the underscored target (valid shell identifiers
  under `__structuredAttrs`; cc-rs finds both forms). Done.
