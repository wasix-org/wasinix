# Adding a package

Pick the lightest form (the loader `pkgs/lib/load-packages.nix` picks all of
these up automatically):

- **No tweaks** → add the name to `pkgs/overlay/trivial.nix` (it becomes
  `libTweaks {} prev.<name>`). No file.
- **Tweaks, no assets** → a single `pkgs/overlay/packages/<name>.nix`.
- **Has patches/tests/aux** → a dir `pkgs/overlay/packages/<name>/` with
  `package.nix` + `patches/` + `tests/`.

Every package file is a function over one callArgs attrset:

```nix
{ final, prev, helpers, foundation, preferredPackages, nixpkgs, ... }: …
```

- `prev.<pkg>` — the nixpkgs package, already building with the wasix cross
  stdenv (linked deps auto-thread).
- `final.<dep>` — a same-profile dep you reference explicitly.
- `preferredPackages.<tool>` — a non-linked / runtime-invoked dep, resolved to
  *that tool's* preferred profile (e.g. the off-profile bash).
- `helpers` — `pkgs/lib/default.nix`.

## Tweaks: `libTweaks` / `extendDrv`

`helpers.libTweaks { <attrs> } prev.foo` merges tweaks onto the package
**by kind** (see `extendDrv`):

| value kind | merge behaviour |
|---|---|
| script phase (`postInstall`, `preBuild`, …) | concatenated onto the old value |
| list | appended to the old list |
| attrset (`env`, `meta`, `passthru`) | deep-merged (nested lists append too) |
| scalar / derivation / path | set (replaces) |
| **function** | applied to the old value — the escape for filter/replace |

`doCheck = false` is defaulted (cross can't run target tests). Don't hand-write
`(old.X or []) ++ …` boilerplate; that's what the merge rules are for.

## A library (linked dependency)

```nix
# pkgs/overlay/packages/foo.nix
{ prev, helpers, ... }:
helpers.libTweaks { configureFlags = [ "--disable-bar" ]; } prev.foo
```

If it only works on some profiles, declare it — never touch meta directly:

```nix
passthru.wasix.supportedProfiles = helpers.profiles.withoutPic;
# or, for a genuine defect that should eventually work:
passthru.wasix.broken = "why + upstream link";
```

It's then available as `profileSets.<profile>.foo` and (unless shipped) in the
per-profile `libraryMatrix`.

## A Rust CLI

Usually just `{ prev, ... }: prev.foo` — the rustPlatform seam
(`pkgs/set/rust-platform.nix`, cargo-wasix underneath) builds it, installs the
emitted `.wasm`s, and scopes it to the profiles the rust toolchain targets
(eh/ehpic) via the contract. Tweaks use `libTweaks` exactly like C. For a crate
not in nixpkgs, call `final.rustPlatform.buildRustPackage` directly (see
`packages/crabsay.nix`).

## A CLI shipped as a webc package

1. Wrap with `wasmRename` to publish `bin/foo` as `foo.wasm` (add
   `asyncifyFlags`/`binaryen` if it needs fork/longjmp), and add `"foo"` to
   `shippedCommands` in `pkgs/default.nix`:

   ```nix
   { prev, helpers, ... }:
   helpers.wasmRename { wasmName = "foo"; } (helpers.libTweaks { } prev.foo)
   ```

2. The webc `wasmer.toml` is derived automatically
   (`pkgs/wasmer/make-wasmer-package.nix`); only deviations go in
   `passthru.wasmer` — most packages need none. Knobs:
   `name` (default `meta.mainProgram`), `version`, `commands` (for aliases like
   gunzip→gzip), `fs."<guest>" = <store path>`, `commandEnv.<cmd>`,
   `autoSelfMount` (mount the store paths the wasm embeds), `selfMounts` (paths
   autoSelfMount can't see — e.g. ones baked into a `.py`). Example (git):

   ```nix
   passthru.wasmer = {
     owner = "kilyanni";
     fs."/etc/ssl" = "${final.cacert}/etc/ssl";
     commandEnv.git = { SSL_CERT_FILE = "/etc/ssl/certs/ca-bundle.crt"; };
     autoSelfMount = true;
   };
   ```

## A Python override or wheel

- **Ship a wheel**: add `{attr = "<python3.pkgs attr>";}` to
  `pkgs/overlay/python-packages/wheels.nix` (plus `pyImport` if the module name
  differs from the attr, `skipTest` rarely). Most wheels need nothing else.
- **Build fix**: add `overlay/python-packages/<attr>.nix` — same convention as
  top-level package files, with `pyfinal`/`pyprev` added to the callArgs for
  python-set deps (`final.<x>` stays for C libraries). Patches go in
  `python-packages/patches/`; shared rust/pyo3 and wheel helpers in
  `python-packages/lib/`.

Only add an override for real build fixes — nixpkgs' cross machinery already
skips the run-only phases (doCheck, pythonImportsCheck).

## Tests

Drop `pkgs/overlay/packages/<name>/tests/*.nix` — each returns an attrset of
`testLib`-built derivations (a `helpers.nix` is shared setup). They attach to
the webc package as `passthru.tests`, run under wasmer, and surface as
`checks.<name>`. See the harness in `pkgs/wasmer/test-lib.nix`:
`mkScriptComparison` diffs against the native tool; `expectFail` marks a
negative test; `broken "reason"` tolerates a known defect without blocking CI
and hard-fails (XPASS) once it starts passing, so markers can't go stale.

## Pitfalls

- `nix build .#…` uses the **git-tracked** flake source — `git add` new files
  first (or use `path:$PWD` while iterating).
- `bash` and anything off-only build in the `off` profile; building them in
  another profile asserts by design. Reach them via `preferredPackages`.
- Autoconf conftests tripped by wasm-opt → add
  `disableWasmOptInConfigureHook` (from the overlay) to `nativeBuildInputs`
  instead of disabling wasm-opt globally.
- Check `WASIX-TODO.md` before debugging a weird runtime failure — it's likely
  a known quirk with an established workaround pattern.
