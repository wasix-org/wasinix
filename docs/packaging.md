# Adding a package

Lightest form that works (the loader finds all of these):

- No changes: name in `pkgs/overlay/trivial.nix`.
- Changes, no extra files: `pkgs/overlay/packages/<name>.nix`.
- Patches/tests: `pkgs/overlay/packages/<name>/` with `package.nix`,
  `patches/`, `tests/`.

A package file is a function over one argument set:

```nix
{ final, prev, helpers, foundation, preferredPackages, nixpkgs, ... }: ...
```

`prev.<name>` is the nixpkgs package, already compiling with the WASIX stdenv
and resolving deps within the profile. `final.<dep>` names a same-profile dep
explicitly. `preferredPackages.<tool>` is for tools executed at runtime,
which may need another profile (bash only builds in `off`).

## Tweaks

`helpers.libTweaks { <attrs> } prev.foo` merges attributes by kind: phases
concatenate, lists append, attrsets merge recursively, scalars replace, a
function gets the old value. `doCheck = false` is the default. Don't write
`(old.X or []) ++ ...` by hand.

## A library

```nix
{ prev, helpers, ... }:
helpers.libTweaks { configureFlags = [ "--disable-bar" ]; } prev.foo
```

Profile limits are declared, never written to meta directly:

```nix
passthru.wasix.supportedProfiles = helpers.profiles.withoutPic;
passthru.wasix.broken = "reason + upstream link";   # defect, not a limit
```

The result is `profileSets.<profile>.foo`, and a `libraryMatrix` entry unless
it's a shipped CLI.

## A Rust CLI

Usually `{ prev, ... }: prev.foo`; the WASIX rustPlatform builds it through
cargo-wasix, installs the `.wasm`s, and limits it to `eh`/`ehpic`. For crates
not in nixpkgs, call `final.rustPlatform.buildRustPackage` (see
`packages/crabsay.nix`).

## A CLI shipped as webc

1. Rename the binary to `<name>.wasm` and list it in `shippedCommands`
   (`pkgs/default.nix`):

   ```nix
   { prev, helpers, ... }:
   helpers.wasmRename { wasmName = "foo"; } (helpers.libTweaks { } prev.foo)
   ```

   Programs needing fork/setjmp set `env.WASIXCC_WASM_OPT_FLAGS =
   "--asyncify:-O2"` so wasixcc asyncifies at link (see `find`, `gitMinimal`).

2. The webc manifest is generated; most packages need zero config. Deviations
   go in `passthru.wasmer`: `name`, `version`, `commands` (aliases),
   `fs."<path>" = <store path>`, `commandEnv.<cmd>`, `autoSelfMount` (mount
   store paths found in the wasm), `selfMounts` (paths referenced from
   scripts, which autoSelfMount can't see). See git's package.nix for a full
   example.

## Publishing to the registry

`scripts/wasmer-publish-all.py --registry wasmer.io` builds `allWasmer` and
publishes every shipped webc the registry does not already have (`--dry-run`
previews). Existing versions are hash-verified against the registry, so a
changed webc under an unchanged version fails loudly. Needs an authenticated
`wasmer` CLI (`wasmer login`). Packages publish in name order; the only
cross-package webc dependency (git → bash) is satisfied by it.

## A Python package or wheel

- Ship a wheel: add `{attr = "<python3.pkgs name>";}` to
  `overlay/python-packages/wheels.nix` (`pyImport` if the module name
  differs). Most need nothing else; test phases are already skipped by cross.
- Fix a build: `overlay/python-packages/<attr>.nix`, same form as top-level
  plus `pyfinal`/`pyprev` for Python-set deps. Patches in
  `python-packages/patches/`, Rust-wheel helpers in `python-packages/lib/`.

All shipped wheels (plus their transitive python deps) are also published as a
static PEP 503 "simple" index: `.#pythonRegistry` (`pkgs/python-registry/`).
Serve the output from any static file host, or install directly:
`pip install --index-url file://$(readlink -f result)/simple <pkg>`. A new
wheels.nix entry lands in the registry automatically. Its test suite
(`checks.python-registry`) walks the index for hash/metadata integrity and
pip-installs representative packages (deps resolved from the index too), then
imports them under wasmer.

## Tests

`pkgs/overlay/packages/<name>/tests/*.nix`, each returning an attrset of
derivations built with `pkgs/wasmer/test-lib.nix` (a `helpers.nix` is shared
setup). They attach as `passthru.tests` and appear under `checks.<name>`.
`mkScriptComparison` diffs against the native tool; `expectFail` marks a
must-fail test; `broken "reason"` tolerates a known failure and fails loudly
once it starts passing.

To run tests against a locally built runtime instead of the pinned one:
`WASMER_BIN=/path/to/wasmer nix build --impure .#checks.x86_64-linux.<name>`.

## Pitfalls

- `nix build` reads the git-tracked tree; `git add` new files first.
- Off-only packages fail in other profiles on purpose; use
  `preferredPackages`.
- `configure` misdetecting features can be wasm-opt failing on test programs:
  add `disableWasmOptInConfigureHook` to `nativeBuildInputs`.
- Check `WASIX-TODO.md` before debugging odd runtime behaviour.
