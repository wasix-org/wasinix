# Adding a package

Writing the recipe and its tests. Getting the result out to consumers, and
keeping older versions rebuildable, is `docs/registry.md`.

## A package provided natively and for WASIX

Put the complete definition in
`pkgs/overlays/<first-character>/<name>/package.nix`. The unit runs in the
native package set and every WASIX profile set:

```nix
{
  exposePackage,
  packageSet,
}:
exposePackage (packageSet.callPackage ./build.nix {})
```

`build.nix` is an ordinary nixpkgs-style package function. Use arguments such as
`stdenv`, `rustPlatform`, and named dependencies. Where the native and WASIX
builds differ in something small, branch on `stdenv.hostPlatform.isWasix` inside
that definition. A unit needing different top-level constructions may instead
request `scope`, `variant`, and `packageSet` in `package.nix` and return the
appropriate derivation from one visible definition.

The results are `packages.native.<name>` and `packages.wasix.<profile>.<name>`.
`packages.preferred.<name>` remains the convenient canonical WASIX build.

## Adapting a nixpkgs package for WASIX

The regular inventory uses one-character buckets. A WASIX-only adaptation uses
one of these forms:

- No support files: `pkgs/overlays/<first-character>/<name>.nix`.
- Patches or tests: `pkgs/overlays/<first-character>/<name>/wasix.nix` with
  sibling `patches/` and `tests/` directories.
- Version families: one directory whose unit returns several derivations with
  `exposeWasixExtendedPackages`. See `pkgs/overlays/i/icu/`.

A package file is a function over one argument set:

```nix
{package, packages, exposeWasixPackage, exposeWasixExtendedPackage, ...}: ...
```

`package` is the preceding value of the discovered attribute.
`packages.sameProfile.<dep>` is the immediate recursive package set, already
using the WASIX stdenv for the current profile. `packages.preferred.<tool>` is
for runtime tools that may deliberately use another profile.

Use `packages.sameProfile` for linked dependencies. Reaching into an absolute
profile view from a package unit pins a profile the package does not control.

The loader never instantiates `wasix.nix` in a native package set or native
build-package splice. A `package.nix` is the form for a definition that owns its
native behavior too. `exposeNativePackage` declares a complete package with no
WASIX variant; WASIX package sets reuse that native result as host-side
construction plumbing instead of instantiating the unit again. An entry cannot
contain both files, and `recipe.nix` is not a supported entry form.

An empty `supportedProfiles` only keeps an instantiated package out of WASIX
catalog projections. It does not make the package native-only;
`exposeNativePackage` is the construction-level declaration for that behavior.

Patches live next to the file that applies them, so a package's patches belong
in its own `patches/` directory and shared toolchain plumbing remains under
`pkgs/toolchain/`. Do not vendor a file, lockfile, or bindist without stating
the reason in the commit. Prefer nixpkgs plus a vendored patch over maintaining
separate sources, and a version tag over a pinned hash.

## Tweaks

`exposeWasixExtendedPackage {<attrs>}` extends and exposes the preceding package
inside a WASIX adaptation. `exposeExtendedPackage` is the scope-independent form
for a complete package unit that deliberately extends a preceding value. Their
`extendPackage` merge concatenates phases, appends lists, recursively merges
non-derivation attrsets, lets a function transform the old value, and replaces
other values. It does not choose check policy. Use `extendPackage package attrs`
directly when a unit needs the intermediate derivation.

## A library

```nix
{exposeWasixExtendedPackage}:
exposeWasixExtendedPackage {configureFlags = ["--disable-bar"];}
```

Profile limits are declared, never written to meta directly:

```nix
passthru.wasix.supportedProfiles = profileSets.withoutPic;
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
};
passthru.wasinix.ci.profiles = ["eh" "ehpic"];
```

`wasinix.ci.profiles` must be a subset of `supportedProfiles`. The complete
result is always available as `packages.wasix.<profile>.foo`; CI selects from
that matrix using the package declaration.

## A Rust CLI

Usually `{exposeWasixPackage, package}: exposeWasixPackage package`; the WASIX
`rustPlatform` builds it through cargo-wasix and installs the `.wasm` files.
Crates not in nixpkgs, crate edits, and the overlay registry: `docs/rust.md`.

## A CLI shipped as webc

1. Rename the binary to `<name>.wasm` and declare it shipped:

   ```nix
   {exposeWasixPackage, extendPackage, package, wasmRename}:
   exposeWasixPackage (wasmRename {wasmName = "foo";} (extendPackage package {
     passthru.wasinix.shipped = true;
   }))
   ```

   Programs needing `fork()` or `setjmp` set
   `env.WASIXCC_WASM_OPT_FLAGS = "--asyncify:-O2"` so wasixcc asyncifies at link
   time.

2. The webc manifest is generated; most packages need zero config. Deviations go
   in `passthru.wasmer`: `name`, `version`, `commands` (manifest command
   aliases), `entrypoint`, `fs."<path>" = <store path>`, `env` (set on every
   command), `commandEnv.<cmd>`, `autoSelfMount` (mount store paths found in the
   wasm), `selfMounts` (paths referenced from scripts, which autoSelfMount can't
   see). See git's package.nix for an example with several deviations. Public
   package aliases belong in `passthru.wasinix.aliases`.

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
       dependency = wasmerDependencies.any packages.preferred.bash;
     }
   ];
   ```

   Runtime webc dependencies accept a derivation or an attrset containing
   `package` and `version`. The helpers derive requirements from the package's
   published webc version:

   ```nix
   passthru.wasmer.dependencies = [
     packages.preferred.foo
     (wasmerDependencies.any packages.preferred.bar)
     (wasmerDependencies.exact packages.preferred.baz)
     (wasmerDependencies.compatibleMajor packages.preferred.qux)
     (wasmerDependencies.compatibleMinor packages.preferred.quux)
   ];
   ```

   A bare derivation retains the default semver-compatible requirement. Use an
   explicit `{ package = drv; version = "..."; }` for another semver range.

3. Ship an older release too (a version consumers pin): see
   [Registry history](registry.md#registry-history).

## A Python package or wheel

- Ship a wheel: add `{attr = "<python3.pkgs name>";}` to
  `pkgs/python/wheels/default.nix` (`pyImport` if the module name differs). Most
  need no adaptation; compatible package suites run through the emulated check
  machinery.
- Fix a build: `pkgs/python-overlays/<first-character>/<attr>.nix`, using
  `packages.sameProfile` for Python dependencies and `pkgs` for the enclosing
  WASIX set. An entry with support files uses `<attr>/package.nix`; patches stay
  in that directory. Rust-wheel helpers live in `pkgs/python/lib/`.
- Ship an older release too (a version consumers pin): see
  [Registry history](registry.md#registry-history).
- Which wheel to add next, and what it unblocks: `python-coverage.md`.

## Tests

`pkgs/overlays/<first-character>/<name>/tests/*.nix` files receive the same
final context as package construction plus `entry`, the completed catalog entry.
Each returns an attrset of test derivations. A sibling `helpers.nix` can provide
shared setup. Tests are catalog projections under `tests.<subject>.<name>`; they
are not attached back to packages as an authoritative `passthru.tests` tree.

Use `entry.commands` and `harnesses.hostShell` for packaged command behavior, or
`harnesses.wasixShell` when the workflow belongs inside WASIX. Host fixtures and
server setup belong in the harness's explicit host setup. For a generated
consumer, build against `packages.sameProfile` and use
`harnesses.packageCommand` to package the result.

Python wheel tests use `harnesses.python`. It copies the wheel and explicit test
dependencies into a clean target, runs the packaged Python WebC under Wasmer,
and does not mount the Nix store. Python tests live at
`pkgs/python-overlays/<first-character>/<attr>/tests/*.nix`; use the directory
form whenever an adaptation needs tests or other support files.

Every wheel also gets the guards in `pkgs/python/wheels/project.nix`: `import`
runs the module on the shipped python, `self-contained` rejects a baked
`/nix/store` path, and `deps` checks the published METADATA names only
distributions the registry serves. The first two read the installed closure, so
`deps` is what covers the artifact pip actually resolves; `skipTest` gates only
the guards that import.

To run tests against a locally built runtime instead of the pinned one:
`WASMER_BIN=/path/to/wasmer nix build --impure .#checks.x86_64-linux.<name>`.

### Emulated build-system checks

Packages with `doCheck` capture their configured test tree and build environment
in a compressed `check` output. `pkgs/checks/emulated.nix` restores that output
and runs the declared check phase under Wasmer, without adding the runtime to
the package build closure. Executable wasm test programs are exposed through
host-side wrappers so build systems can invoke them by filename.

C and C++ packages use their nixpkgs `checkPhase`. Python wheels use the native
nixpkgs custom `installCheckPhase` or check hook. Override that choice with
`passthru.wasinix.checks.captured.install`; configure the run with
`passthru.wasinix.checks.captured` (`timeout`, `expectFail`, `broken`, or
`tags`). Large Python suites can set `shards = N`; pytest checks partition
collected node IDs deterministically, while custom phases consume
`WASIX_CHECK_SHARD_COUNT` and `WASIX_CHECK_SHARD_NUM` themselves.

Captured checks appear as catalog tests named `captured`; shards add their
number to that name. Handwritten package tests remain appropriate for focused
behavior and for suites that cannot use the installed package tree. Historical
instances receive the same applicable tests, tagged `history-tests` so normal CI
does not execute them.

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
- Off-only packages fail in other profiles on purpose; use `packages.preferred`.
- `configure` misdetecting features can be wasm-opt failing on test programs:
  add `disableWasmOptInConfigureHook` to `nativeBuildInputs`.
- Odd runtime behaviour, such as unexpected exit codes or output formatting, is
  usually a known WASIX quirk rather than a bug in the package, so check
  `WASIX-TODO.md` first. Older entries are still being triaged onto its entry
  format, so verify one against the current toolchain before relying on it.
  Adding an entry follows the format in that file's header.
