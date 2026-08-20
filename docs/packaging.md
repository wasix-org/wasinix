# Adding a package

Writing the recipe and its tests. Getting the result out to consumers, and
keeping older versions rebuildable, is `docs/registry.md`.

## A package provided natively and for WASIX

Put its standard nixpkgs-style recipe in `pkgs/products/<name>/package.nix`. The
directory is enumerated automatically and the recipe is called in both the
native package set and every WASIX profile set. Use ordinary function arguments
such as `stdenv`, `rustPlatform`, and named dependencies; do not take a native
build from a cross set's `buildPackages`.

Keep the matching overlay entry. Put only WASIX-specific adaptation in
`pkgs/overlay/packages/<name>/package.nix`, deriving from the preceding shared
recipe:

```nix
{prev, helpers, ...}:
helpers.libTweaks {
  passthru.wasix.shipped = true;
} prev.foo
```

Where the native and WASIX builds differ in something small, branch on
`stdenv.hostPlatform.isWasix` inside the shared recipe rather than forking it
into two.

The results are `nativePackages.<name>` and
`packagesByProfile.<profile>.<name>`. `preferredProfilePackages.<name>` remains
the convenient canonical WASIX build.

## A WASIX-only package

Lightest form that works (the loader finds all of these):

- No changes: name in `pkgs/overlay/trivial.nix`.
- Changes, no extra files: `pkgs/overlay/packages/<name>.nix`.
- Patches/tests: `pkgs/overlay/packages/<name>/` with `package.nix`, `patches/`,
  `tests/`.
- Version families: one dir whose `package.nix` evaluates to `{names, packages}`
  instead of a function; `names` is the static attr list it provides,
  `packages = callArgs: {<name> = drv;}`. See `pkgs/overlay/packages/icu/` for
  an example.

A package file is a function over one argument set:

```nix
{ final, prev, helpers, toolchain, preferredProfilePackages, wasmerDependencies, nixpkgs, ... }: ...
```

`prev.<name>` is the nixpkgs package, already compiling with the WASIX stdenv
and resolving deps within the profile. `final.<dep>` names a same-profile dep
explicitly. `preferredProfilePackages.<tool>` is for tools executed at runtime,
which may need another profile.

Those two are the only ways a package file names a dependency. Reaching for
`nixpkgsByProfile.<profile>.<dep>` from a package file pins a profile the
package does not control; use `final` for linking and `preferredProfilePackages`
for runtime tools.

Patches live next to the file that applies them, so a package's patches belong
in its own `patches/` directory and toolchain patches under `pkgs/toolchain/`.
Do not vendor a file, lockfile, or bindist without stating the reason in the
commit. Prefer nixpkgs plus a vendored patch over maintaining separate sources,
and a version tag over a pinned hash.

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

CI coverage is separate from support. It defaults to every supported profile, or
to the singleton explicit `preferredProfile` when one is declared. Shipped
products likewise default to their effective preferred profile. Override it
without hiding the other supported builds:

```nix
passthru.wasix = {
  supportedProfiles = ["eh" "ehpic"];
  preferredProfile = "eh";
  ciProfiles = ["eh" "ehpic"];
};
```

`ciProfiles` must be a subset of `supportedProfiles`. The complete result is
always available as `packagesByProfile.<profile>.foo`; CI selects from that
matrix using the package declaration.

## A Rust CLI

Usually `{ prev, ... }: prev.foo`; the WASIX rustPlatform builds it through
cargo-wasix, installs the `.wasm`s, and limits it to `eh`/`ehpic`. Crates not in
nixpkgs, crate edits, and the overlay registry: `docs/rust.md`.

## A CLI shipped as webc

1. Rename the binary to `<name>.wasm` and declare it shipped (`shippedCommands`
   in `pkgs/default.nix` is derived from the flag):

   ```nix
   { prev, helpers, ... }:
   helpers.wasmRename { wasmName = "foo"; } (helpers.libTweaks {
     passthru.wasix.shipped = true;
   } prev.foo)
   ```

   Programs needing `fork()` or `setjmp` set
   `env.WASIXCC_WASM_OPT_FLAGS = "--asyncify:-O2"` so wasixcc asyncifies at link
   time.

2. The webc manifest is generated; most packages need zero config. Deviations go
   in `passthru.wasmer`: `name`, `version`, `aliases` (`wasmerPackages` attr
   aliases), `commands` (manifest command aliases), `entrypoint`,
   `fs."<path>" = <store path>`, `env` (set on every command),
   `commandEnv.<cmd>`, `autoSelfMount` (mount store paths found in the wasm),
   `selfMounts` (paths referenced from scripts, which autoSelfMount can't see).
   See git's package.nix for an example with several deviations.

   `aliases` are explicit public addresses for the same package. They must not
   collide with a canonical published-name key or resolve to different packages.
   Publication, CI, and aggregate generation use only canonical entries.

   `commands` also names several commands on one module, which is how bash
   serves `sh` and coreutils serves a command per program without repeating the
   wasm. More than one command means wasmer no longer infers an entrypoint, so
   set one.

   A metapackage can re-export a command from one of its dependencies without
   embedding that module. The command adds the dependency itself and derives the
   qualified module and atom from its published identity:

   ```nix
   passthru.wasmer.commands = [
     {
       name = "bash";
       dependency = wasmerDependencies.any preferredProfilePackages.bash;
     }
   ];
   ```

   Runtime webc dependencies accept a derivation or an attrset containing
   `package` and `version`. The helpers derive requirements from the package's
   published webc version:

   ```nix
   passthru.wasmer.dependencies = [
     preferredProfilePackages.foo
     (wasmerDependencies.any preferredProfilePackages.bar)
     (wasmerDependencies.exact preferredProfilePackages.baz)
     (wasmerDependencies.compatibleMajor preferredProfilePackages.qux)
     (wasmerDependencies.compatibleMinor preferredProfilePackages.quux)
   ];
   ```

   A bare derivation retains the default semver-compatible requirement. Use an
   explicit `{ package = drv; version = "..."; }` for another semver range.

3. Ship an older release too (a version consumers pin): see
   [Registry history](registry.md#registry-history).

## A Python package or wheel

- Ship a wheel: add `{attr = "<python3.pkgs name>";}` to
  `pkgs/overlay/python-packages/wheels.nix` (`pyImport` if the module name
  differs). Most need nothing else; test phases are already skipped by cross.
- Fix a build: `pkgs/overlay/python-packages/<attr>.nix`, same form as top-level
  plus `pyfinal`/`pyprev` for Python-set deps. Patches live in
  `pkgs/overlay/python-packages/patches/`; Rust-wheel helpers live in
  `pkgs/overlay/python-packages/lib/`.
- Ship an older release too (a version consumers pin): see
  [Registry history](registry.md#registry-history).
- Which wheel to add next, and what it unblocks: `python-coverage.md`.

## Tests

`pkgs/overlay/packages/<name>/tests/*.nix`, each returning an attrset of
derivations built with `pkgs/wasmer/test-lib.nix` (a `helpers.nix` is shared
setup). They attach as `passthru.tests` and appear under
`checks.<system>.<name>`. Besides `pkgs`/`testLib`/`wasmerPkgs`, test files can
take `preferredProfilePackages`, `crossPkgs` (the default-profile cross set),
and `makeWasmerPackage` to cross-build and package a consumer program. See
icu-data's smoke test for an example. `mkScriptComparison` diffs against the
native tool; `expectFail` marks a must-fail test; `broken "reason"` tolerates a
known failure and fails loudly once it starts passing.

Every wheel also gets the guards in `pkgs/python-wheels.nix`: `import` runs the
module on the shipped python, `self-contained` rejects a baked `/nix/store`
path, and `deps` checks the published METADATA names only distributions the
registry serves. The first two read the installed closure, so `deps` is what
covers the artifact pip actually resolves; `skipTest` gates only the guards that
import.

To run tests against a locally built runtime instead of the pinned one:
`WASMER_BIN=/path/to/wasmer nix build --impure .#checks.x86_64-linux.<name>`.

### Emulated build-system checks

Packages with `doCheck` capture their configured test tree and build environment
in a compressed `check` output. `pkgs/emulated-check.nix` restores that output
and runs the declared check phase under Wasmer, without adding the runtime to
the package build closure. Executable wasm test programs are exposed through
host-side wrappers so build systems can invoke them by filename.

C and C++ packages use their nixpkgs `checkPhase`. Python wheels use the native
nixpkgs custom `installCheckPhase` or check hook. Override that choice with
`passthru.wasix.installCheck`; configure the run with
`passthru.wasix.emulatedCheck` (`timeout`, `expectFail`, `broken`, or `ciTags`).
Large Python suites can set `shards = N`; pytest checks partition collected node
IDs deterministically, while custom phases consume `WASIX_CHECK_SHARD_COUNT` and
`WASIX_CHECK_SHARD_NUM` themselves.

Unsharded checks appear as `passthru.tests.upstream`; sharded checks use
`upstream-<number>-of-<count>`. Handwritten package tests remain appropriate for
focused behavior and for suites that cannot use the installed package tree.
`pkgs/python-closure-tests.nix` separately imports the dependency closure of
every shipped wheel.

## Update scripts

A package that pins its own source (rather than overriding nixpkgs) declares its
bump in `passthru.updateScript` (`docs/updating.md`). Verify the script end to
end locally before shipping it: downgrade to an explicit older release
(`wasinix update <target>@<version>`, or `@rev:<sha>` for revision targets),
then update back to latest (`wasinix update <target>`), and check both edits
land in the pin file. A script that has only ever answered "already up to date"
has exercised none of its rewriting.

## Pitfalls

- Nix only sees git-tracked files, so `git add -N` a new one before building
  (`docs/building.md`).
- Off-only packages fail in other profiles on purpose; use
  `preferredProfilePackages`.
- `configure` misdetecting features can be wasm-opt failing on test programs:
  add `disableWasmOptInConfigureHook` to `nativeBuildInputs`.
- Odd runtime behaviour, such as unexpected exit codes or output formatting, is
  usually a known WASIX quirk rather than a bug in the package, so check
  `WASIX-TODO.md` first. Older entries are still being triaged onto its entry
  format, so verify one against the current toolchain before relying on it.
  Adding an entry follows the format in that file's header.
