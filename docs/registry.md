# Registry and publishing

Getting a built package out to consumers: webcs on the wasmer registry, wheels
on the Python index, the older versions we keep rebuildable, and PR previews.
Authoring the package itself is `docs/packaging.md`.

## Publishing webcs

```sh
nix run .#scripts.publish-webc -- --registry wasmer.io [name...]
```

Builds the named webcs (none = all shipped) and publishes those the registry
does not already have. `--dry-run` previews.

- **Auth**: `wasmer login`, or `WASMER_TOKEN`.
- **Order**: packages publish in dependency order. A webc dependency that is
  neither already published nor part of this run is an error.
- **Existing versions** are hash-verified against the registry, so a changed
  webc under an unchanged version fails loudly. Republishing one needs a rel
  encoding the registry supports, which does not exist yet (`WASIX-TODO.md`).
- **Failures** are isolated per package and reported at the end.
- **Owner**: webcs publish under `wasmer/` on wasmer.io, the default in
  `pkgs/wasmer/make-wasmer-package.nix`.
- **Provenance** rides the package README: the generated README carries the attr
  and rel, and the publish step appends the source rev and a rebuild command.
  Verification restages the local build with the recorded rev to reproduce the
  published bytes, then compares registry hashes (`wasmer publish` can exit 0
  without tagging, `WASIX-TODO.md`).

The `publish-webc` workflow runs the same script, manual dispatch only, with the
`WASMER_TOKEN` secret.

## Registry history

Both registries are append-only. History entries also keep selected older
versions rebuildable, using one table per package set:

- wheels: `pkgs/overlay/python-packages/history.json`
- CLIs / libraries: `pkgs/overlay/packages/history.json`

Tables are keyed `{<attr>: {<version>: <spec>}}`. A spec contains the fields for
the package's existing source fetcher: `{version, hash}`, `{tag|rev, hash}`, or
`{url, hash}`. Rust packages may add `cargoHash`; `note` and `variants` are
optional. A wheel uses `variants`, such as `["py313"]`, when an entry applies to
only some interpreters.

`pkgs/lib/load-packages.nix` re-imports the package with its source rebased and
creates `<attr>_<version>`. Package files handle version-specific differences;
`passthru.wasix.historySpec` exposes the history entry when needed.

Keys differ per set, and webcs are normalised:

- wheels: `.#pythonWheels.py313."numpy-2.1.3"`
- webcs: `wasmerPackages` and the run-by-name stubs use `<name>-<semver>`, so a
  test asks for `wasmerPkgs."jq-1.6.0"`.

Webc attrs use full MAJOR.MINOR.PATCH while `history.json` keeps the upstream
version as written. For example, jq `"1.6"` becomes `jq-1.6.0`.

Maintain the tables with `nix run .#scripts.history`. Use
`add <attr>==<version>`, `--per-major`, or `--per-minor`; `--set wheel|cli`
disambiguates shared names. Pin updates retain outgoing major versions by
default. `passthru.wasix.retention = "minor"` keeps each minor, while `"none"`
opts out. Keep only versions consumers are likely to pin.

A `{names, packages}` family is only for a package nixpkgs itself carries at
multiple versions, not for minting historical ones. Its version list should
derive from nixpkgs. For example, icu uses a `retentionHook` to regenerate its
list after a pin bump.

## The Python wheel index

All shipped wheels, plus their transitive python deps, are published as a static
PEP 503 "simple" index: `.#pythonRegistry` (`pkgs/python-registry/`). Serve the
output from any static file host, or install directly:

```sh
pip install --index-url file://$(readlink -f result)/simple <pkg>
```

A new `wheels.nix` entry lands in the registry automatically. Its test suite
(`checks.<system>.python-registry`) walks the index for hash and metadata
integrity and pip-installs representative packages, resolving their deps from
the index too, then imports them under wasmer.

## Rels

Every wheel is published as `<version>+wasix.<rel>`, a PEP 440 local version.
`rel` counts our builds of one upstream version and comes from the root
`rels.json`, keyed by attr path (`pythonRegistry.wheels.<pname>`, or
`wasmerPackages.<name>` for webcs) then version, default 1. It is shared across
python versions, since the cp tag already keeps filenames distinct.

Bump it to republish a changed build, with `nix run .#scripts.bump-rel` or the
manual `bump-rel.yml` workflow, which takes a list of packages and opens a PR.
An upstream version bump resets it by key miss, as `nix run .#scripts.update`
drops the stale key. For a deliberate whole-registry rebuild:

```sh
nix run .#scripts.bump-rel -- --all-versions 'pythonRegistry.wheels.*'
```

That flag also bumps every served history version, so it stays explicit.

Webc rels land in `[package.metadata] wasix-rel` only, for now: the registry has
no version encoding for republishing (`WASIX-TODO.md`), so a bumped webc still
cannot republish.

## Immutability, and the two indexes

Published filenames are immutable and accumulate. A normal registry rebuild can
change the bytes behind an existing filename through a nixpkgs, toolchain, or
runtime update, and the volume keeps its original artifact in that case. Bump
the rel only when that rebuilt wheel is itself a release.

GitHub Pages behaves differently: it is always deployed from the fresh
`.#pythonRegistry` result, so it is a bleeding-edge snapshot and may serve new
bytes under an existing filename. Use the volume-backed index for immutable,
reproducible installs.

After a green build of main, `publish-index` uploads new filenames to the volume
and deploys the fresh snapshot to GitHub Pages. The volume service is defined by
`python-registry/app.yaml`.

Each `manifests/<wheel>.json` records `wasinix_rev`, `attr`, and `drv_path`.
Rebuild it with `nix build github:wasix-org/wasinix/<wasinix_rev>#<attr>`.

## PR previews

Label a same-repo PR `preview`. After its Build goes green, so the CI cache
serves every artifact (labeling an already-green PR triggers immediately),
`preview.yml` diffs it against its base at the drvPath level
(`scripts/preview-diff.py`) and publishes what changed.

Webcs go to the dev registry as `<version>-pr<N>.g<sha7>` prereleases: distinct
versions per iteration, hidden from `latest`, not deletable, so they accumulate
on wasmer.wtf. Changed wheels become an ephemeral per-PR Edge app serving an
overlay index:

```sh
pip install --index-url <preview>/simple --extra-index-url <prod>/simple
```

which prefers the preview wheels by their longer local version. The app is
deleted when the PR closes or drops the label (`preview-cleanup.yml`), and the
PR gets a comment with the URLs.
