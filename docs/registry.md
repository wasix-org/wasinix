# Registry and publishing

Getting a built package out to consumers: webcs on the wasmer registry, wheels
on the Python index, the older versions we keep rebuildable, and PR previews.
Authoring the package itself is `docs/packaging.md`.

Each registry is a CLI noun with the same verbs:
`wasinix cargo|wasmer|python serve` runs one locally, `publish` pushes what is
missing, `preview` deploys an ephemeral copy; `wasinix python count-natives`
counts wheels shipping compiled extensions, and `wasinix python coverage` ranks
the next Python coverage additions. `wasinix serve` stands all three up at once
and tears them down together; `--mint`, `--index`, `--server`, and `--webc`
reuse prebuilt artifacts instead of building fresh.

`wasinix wasmer serve` yields a directory, not a URL: the wasmer CLI has no
local-HTTP registry mode (`--registry` always resolves a remote GraphQL
endpoint), so the cell materializes the selected packages and their dependency
closures as one merged `--offline --include-webc` tree, which is wasmer's native
offline consumption; `--exec` runs a command with `WASMER_FLAGS` pointing at it.
Merging refuses two sources that disagree about the bytes of the same webc path.

## Publishing webcs

```sh
wasinix wasmer publish --registry wasmer.io [name...]
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
- **One-off identity**: `--as [<namespace>/]<name>[@<version>]` publishes a
  single package under a different identity, rewriting the staged manifest.
  Whatever the spec omits keeps the manifest's value, and a bare name keeps the
  namespace. It needs exactly one selected package, since a renamed dependency
  would leave its dependents pinned to a name the registry lacks.
- **Provenance** rides the package README: the generated README carries the attr
  and rel, and the publish step appends the source rev and a rebuild command.
  Verification restages the local build with the recorded rev to reproduce the
  published bytes, then compares registry hashes (`wasmer publish` can exit 0
  without tagging, `WASIX-TODO.md`).

The `publish-webc` workflow runs the same command, manual dispatch only, with
the `WASMER_TOKEN` secret.

## Publishing crates

```sh
wasinix cargo publish [--registry <url>] [--mint <built>] [--dry-run] [name[@version]...]
```

Publishes the minted crates the deployed overlay registry
(cargo-registry.wasix.org) lacks, using the shared Cargo registry wire library,
and reports one plan row per crate (`--json` for the document). Idempotent by
checksum against the live sparse index: an absent version publishes, identical
bytes skip, and different bytes fail naming the
`wasinix versions bump cargoRegistry.crates.<name>@<version>` that mints a fresh
publishable version. A live publish needs `WASIX_CARGO_TOKEN` (a token whose
sha256 is in the deployed server's hash list); dry runs never read it. The
`publish-crates` workflow runs the same command, manual dispatch only.

`wasinix cargo preview` deploys the mint (or, with `--base`, only the crates
whose minted bytes changed) as a static sparse index on an ephemeral Edge app,
the same lifecycle as the wheel preview; `wasinix preview` includes it and the
PR comment names the registry spelling to resolve against it. A static index
cannot pass entries through to crates.io, so it is consumed as a separate
registry rather than a crates-io replacement; that is enough for reviewing
individual crates.

`cargo-registry-wire` owns the normalized-manifest translation used by both
publishing and sparse previews. It is a narrow package because derivation tests
also render sparse indexes; those tests must not depend on the main CLI and
rebuild when unrelated orchestration code changes.

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

A package may declare stable `passthru.wasmer.aliases` for public Nix addresses.
These resolve to the canonical entry but do not create another publication.

Webc attrs use full MAJOR.MINOR.PATCH while `history.json` keeps the upstream
version as written. For example, jq `"1.6"` becomes `jq-1.6.0`.

Maintain the tables with `wasinix versions add` / `versions import`. Use
`add <name>@<version>`, `--per-major`, or `--per-minor`; an address prefix
(`pythonWheels.<name>` / `wasmerPackages.<name>`) disambiguates shared names.
Pin updates retain outgoing major versions by default.
`passthru.wasix.retention = "minor"` keeps each minor, while `"none"` opts out.
Keep only versions consumers are likely to pin.

A `{names, packages}` family is only for a package nixpkgs itself carries at
multiple versions, not for minting historical ones. Its version list should
derive from nixpkgs. For example, icu uses a `postUpdateHook` to regenerate its
list after a pin bump.

## The Python wheel index

All shipped wheels, plus their transitive python deps, are published as a static
PEP 503 "simple" index: `.#pythonRegistry` (`pkgs/python-registry/`). Serve the
output from any static file host, or install directly:

```sh
pip install --index-url file://$(readlink -f result)/all/simple <pkg>
```

A new `wheels.nix` entry lands in the registry automatically. Its test suite
(`checks.<system>.python-registry`) walks the index for hash and metadata
integrity and pip-installs representative packages, resolving their deps from
the index too, then imports them under wasmer. The integrity walk also resolves
every served wheel's `Requires-Dist` against the rest of the index, per
interpreter the wheel installs on, since a resolver has no other source to fall
back to.

`python-registry-resolve-sweep` runs pip itself over every served project, which
catches what a model of pip cannot: a dependency reached only through an extra,
say. A project has to resolve on one interpreter, not all of them, since a
release states its own supported range.

Alongside `simple/`, the index root carries `packages.json`: one JSON object per
line naming a published wheel, which is how `wasmerio/wasmer-compat` decides
which projects the index covers.

`simple/` lists the projects PyPI cannot supply: those shipping a
platform-tagged wheel, and those with an overlay entry here, whose build differs
from upstream's. Point a resolver at it as the priority index beside PyPI:

```sh
uv pip compile pyproject.toml --universal \
  --extra-index-url <index>/simple --index-url https://pypi.org/simple
pip install -r requirements.txt --platform wasix_wasm32 --only-binary :all: --target site
```

uv binds a package to the first index that carries it, so listing a project PyPI
could have supplied pins it to our version and rejects whatever version the
consuming project asks for. Listing one we patched too narrowly is the opposite
defect: the resolver takes upstream's build and drops the patch.

`all/simple/` lists every wheel published here, for installing the closure from
this index alone with no PyPI at all. It carries no wheels of its own; its pages
link to the copies under `simple/<project>/`, where every wheel lives whether or
not its project is listed in `simple/`.

Cross-installing for wasix from a host needs pip. `pip --platform wasix_wasm32`
selects the tagged wheels, while uv's `--python-platform` is a closed enum with
no wasix entry. uv does resolve the index in universal mode
(`uv pip compile --universal`), which commits to no platform, and installs the
pure-python wheels directly. anybuild's template suite
(`pkgs/overlay/packages/anybuild/tests/python-templates.nix`) covers that path
end to end, serving this index over loopback.

## Rels

Every wheel is published as `<version>+wasix.<rel>`, a PEP 440 local version.
`rel` counts our builds of one upstream version and comes from the root
`rels.json`, keyed by attr path (`pythonRegistry.wheels.<pname>`, or
`wasmerPackages.<name>` for webcs) then version, default 1. It is shared across
python versions, since the cp tag already keeps filenames distinct.

Bump it to republish a changed build, with `wasinix versions bump` or the manual
`bump-rel.yml` workflow, which takes a list of packages and opens a PR. An
upstream version bump resets it by key miss, as `wasinix update` drops the stale
key. For a deliberate whole-registry rebuild:

```sh
wasinix versions bump --all-versions 'pythonRegistry.wheels.*'
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

A wheel built by both interpreters is published once, under the one filename its
`py3-none-any` tag earns it. Where the two builds differ, that name cannot hold
both and the registry build fails naming the package. Mark it
`passthru.wasix.interpreterSpecific` in its overlay entry and each build is
published as `cp313-none-any` / `cp314-none-any` instead, which a resolver
prefers over the generic tag, so an artifact already published under the generic
name stops being selected without being withdrawn.

Each `manifests/<wheel>.json` records `wasinix_rev`, `attr`, and `drv_path`.
Rebuild it with `nix build github:wasix-org/wasinix/<wasinix_rev>#<attr>`.

## PR previews

Label a same-repo PR `preview`. After its Build goes green, so the CI cache
serves every artifact (labeling an already-green PR triggers immediately),
`preview.yml` diffs it against its base at the drvPath level and publishes what
changed, all through `wasinix preview`.

Everything lands in the preview namespace `preview.yml` names, on wasmer.io:
prod is where the released packages a preview depends on actually live, and the
namespace keeps prereleases off them. `wasinix preview` requires `--namespace`
and refuses one holding released packages.

Webcs publish there as `<version>-pr<N>.g<sha7>` prereleases: distinct versions
per iteration, hidden from `latest`, not deletable, so they accumulate. Nix's
resolved dependency graph decides which dependencies selected in the same
preview are repinned, independently of whether the manifest requirement is
exact, a range, or `*`. Those dependencies and their qualified command
references are repinned to the namespace and tag; one that is already released
keeps its name and requirement. The standalone `wasinix wasmer preview` expands
the selected packages to their missing dependency closure only with
`--with-dependencies`; without it, every package in the batch must be selected
explicitly or already released. Changed wheels become an ephemeral per-PR Edge
app serving an overlay index:

```sh
pip install --index-url <preview>/all/simple --extra-index-url <prod>/all/simple
```

which prefers the preview wheels by their longer local version. The app is
deleted when the PR closes or drops the label (`preview-cleanup.yml`), and the
PR gets a comment with the URLs.
