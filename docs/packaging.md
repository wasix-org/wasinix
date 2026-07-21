# Adding a package

Lightest form that works (the loader finds all of these):

- No changes: name in `pkgs/overlay/trivial.nix`.
- Changes, no extra files: `pkgs/overlay/packages/<name>.nix`.
- Patches/tests: `pkgs/overlay/packages/<name>/` with `package.nix`,
  `patches/`, `tests/`.
- Version families (icu, icu-data): one dir whose `package.nix` evaluates to
  `{names, packages}` instead of a function; `names` is the static attr list
  it provides, `packages = callArgs: {<name> = drv;}`.

A package file is a function over one argument set:

```nix
{ final, prev, helpers, toolchain, preferredProfilePackages, nixpkgs, ... }: ...
```

`prev.<name>` is the nixpkgs package, already compiling with the WASIX stdenv
and resolving deps within the profile. `final.<dep>` names a same-profile dep
explicitly. `preferredProfilePackages.<tool>` is for tools executed at runtime,
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

The result is `nixpkgsByProfile.<profile>.foo`, and a `librariesByProfile` entry unless
it's a shipped CLI.

## A Rust CLI

Usually `{ prev, ... }: prev.foo`; the WASIX rustPlatform builds it through
cargo-wasix, installs the `.wasm`s, and limits it to `eh`/`ehpic`. For crates
not in nixpkgs, call `final.rustPlatform.buildRustPackage` (see
`packages/crabsay.nix`).

## A CLI shipped as webc

1. Rename the binary to `<name>.wasm` and declare it shipped
   (`shippedCommands` in `pkgs/default.nix` is derived from the flag):

   ```nix
   { prev, helpers, ... }:
   helpers.wasmRename { wasmName = "foo"; } (helpers.libTweaks {
     passthru.wasix.shipped = true;
   } prev.foo)
   ```

   Programs needing fork/setjmp set `env.WASIXCC_WASM_OPT_FLAGS =
"--asyncify:-O2"` so wasixcc asyncifies at link (see `find`, `gitMinimal`).

2. The webc manifest is generated; most packages need zero config. Deviations
   go in `passthru.wasmer`: `name`, `version`, `commands` (aliases),
   `fs."<path>" = <store path>`, `commandEnv.<cmd>`, `autoSelfMount` (mount
   store paths found in the wasm), `selfMounts` (paths referenced from
   scripts, which autoSelfMount can't see). See git's package.nix for a full
   example.

3. Ship an older release too (a version consumers pin): see
   [Registry history](#registry-history).

## Publishing to the registry

`nix run .#scripts.publish-webc -- --registry wasmer.io [name...]` builds the
named webcs (none = all shipped) and publishes those the registry does not
already have (`--dry-run` previews). Existing versions are hash-verified
against the registry, so a changed webc under an unchanged version fails
loudly; republishing one needs a rel encoding the registry supports, which
does not exist yet (WASIX-TODO.md). Auth: `wasmer login` or `WASMER_TOKEN`.
Packages publish in dependency
order; a webc dependency that is neither published nor part of the run is an
error. Failures are isolated per package and reported at the end. Webcs publish under `kilyanni/` until the `wasinix` namespace exists on
wasmer.io (the owner default in `make-wasmer-package.nix`). The `publish-webc`
workflow runs the same script, manual dispatch only, with the `WASMER_TOKEN`
secret. Provenance rides the package README on the registry: the generated
README carries the attr and rel, and the publish step appends the source rev
and a rebuild command. Verification restages the local build with the
recorded rev to reproduce the published bytes, then compares registry hashes
(`wasmer publish` can exit 0 without tagging, WASIX-TODO.md).

## Registry history

Both registries are append-only and never delete, so a version we publish stays
installable forever; a history entry keeps an older version REBUILDABLE too (for
a version consumers still pin, so a regenerated lockfile resolves to it, or to
rel-bump it against a toolchain fix). It works the same for every package set,
one shared table shape, one file per set:

- wheels: `overlay/python-packages/history.json`
- CLIs / libraries: `overlay/packages/history.json`

Keyed `{<attr>: {<version>: <spec>}}`. The spec re-points the package's OWN src
fetcher at that version (its real fetcher, never an imposed one): `{version,
hash}` for `fetchPypi`, `{tag|rev, hash}` for `fetchFromGitHub`, `{url, hash}`
for a `fetchurl` release tarball; plus optional `note` and `variants` (the
set-neutral gate: the build variants an entry is limited to; for wheels a
variant is an interpreter, e.g. `["py313"]`; a single-variant set like CLIs
omits it).

The loader (`load-packages.nix`) mints a `<attr>_<version>` attr in the same
set by re-importing the package file with the src rebased, so the package's own
`lib.version*` conditionals carry the per-version drift (see `numpy.nix`,
`jq/package.nix`). Wheels build at `.#pythonWheels.py313."numpy-2.1.3"`; a
webc keys `wasmerPackages` as `<name>-<semver>` (`jq-1.6.0`) and publishes
under the same webc name. The run-by-name stubs are keyed the same way, so a
test asks for an older build by key: `wasmerPkgs."jq-1.6.0"`.

Maintain the tables with `nix run .#scripts.history`: `add <attr>==<version>`,
or `--per-major`/`--per-minor` where the source has a version index (PyPI, or
github tags for a `fetchFromGitHub` package); `--set wheel|cli` disambiguates a
name in both sets (jq). A nixpkgs bump that crosses a major auto-appends the
outgoing version, for both sets (`scripts/update.py`). Keep history to what
consumers actually pin: latest per major, occasionally latest per minor.

(icu-style `{names, packages}` families are only for packages nixpkgs itself
carries at multiple versions, not for minting historical ones.)

## A Python package or wheel

- Ship a wheel: add `{attr = "<python3.pkgs name>";}` to
  `overlay/python-packages/wheels.nix` (`pyImport` if the module name
  differs). Most need nothing else; test phases are already skipped by cross.
- Fix a build: `overlay/python-packages/<attr>.nix`, same form as top-level
  plus `pyfinal`/`pyprev` for Python-set deps. Patches in
  `python-packages/patches/`, Rust-wheel helpers in `python-packages/lib/`.
- Ship an older release too (a version consumers pin): see
  [Registry history](#registry-history).

All shipped wheels (plus their transitive python deps) are also published as a
static PEP 503 "simple" index: `.#pythonRegistry` (`pkgs/python-registry/`).
Serve the output from any static file host, or install directly:
`pip install --index-url file://$(readlink -f result)/simple <pkg>`. A new
wheels.nix entry lands in the registry automatically. Its test suite
(`checks.python-registry`) walks the index for hash/metadata integrity and
pip-installs representative packages (deps resolved from the index too), then
imports them under wasmer.

Every wheel is published as `<version>+wasix.<rel>` (PEP 440 local version):
`rel` counts our builds of one upstream version and comes from the root
`rels.json`, keyed by attr path (`pythonRegistry.wheels.<pname>`,
`wasmerPackages.<name>` for webcs) then version, default 1, shared across
python versions (the cp tag keeps filenames distinct). Bump it to republish a
changed build, with `nix run .#scripts.bump-rel` or the manual `bump-rel.yml`
workflow (takes a list of packages, opens a PR); an upstream version bump
resets it by key miss (`nix run .#scripts.update` drops the stale key).
Published filenames are immutable and accumulate. Webc rels land in
`[package.metadata] wasix-rel` only for now: the registry has no version
encoding for republishing (WASIX-TODO.md), so a bumped webc still cannot
republish. The `publish-index` workflow (on a green Build of
main) builds the patched wasmer, fetches the volume's S3 credentials with the
`WASMER_TOKEN` secret (provisioning them on the first run via the vendored
`rotateS3Credentials` fix), pushes new wheels with `publish.py`, and deploys a
snapshot to GitHub Pages. The Edge app serving the volume is
`python-registry/app.yaml` (static-web-server, deployed once by hand).

Each wheel's `manifests/<wheel>.json` (served from the volume) records its
build provenance: `wasinix_rev`, `attr`, and `drv_path`. So any wheel is
reproducible with `nix build github:wasix-org/wasinix/<wasinix_rev>#<attr>`
(e.g. `#pythonRegistry.wheels.numpy^dist`); every closure wheel, transitive
deps included, is exposed under `pythonRegistry.wheels`.

## Tests

`pkgs/overlay/packages/<name>/tests/*.nix`, each returning an attrset of
derivations built with `pkgs/wasmer/test-lib.nix` (a `helpers.nix` is shared
setup). They attach as `passthru.tests` and appear under `checks.<name>`.
Besides `pkgs`/`testLib`/`wasmerPkgs`, test files can take `crossPkgs` (the
default-profile cross set) and `makeWasmerPackage` to cross-build and package
a consumer program (see icu-data's smoke test).
`mkScriptComparison` diffs against the native tool; `expectFail` marks a
must-fail test; `broken "reason"` tolerates a known failure and fails loudly
once it starts passing.

To run tests against a locally built runtime instead of the pinned one:
`WASMER_BIN=/path/to/wasmer nix build --impure .#checks.x86_64-linux.<name>`.

## Pitfalls

- `nix build` reads the git-tracked tree; `git add` new files first.
- Off-only packages fail in other profiles on purpose; use
  `preferredProfilePackages`.
- `configure` misdetecting features can be wasm-opt failing on test programs:
  add `disableWasmOptInConfigureHook` to `nativeBuildInputs`.
- Check `WASIX-TODO.md` before debugging odd runtime behaviour.
