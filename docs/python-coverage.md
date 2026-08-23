# Python coverage roadmap

How much of PyPI installs on wasix, what blocks the rest, and in what order to
fix it. Numbers come from the vendored `pypi-survey/` (top-10k PyPI packages by
30-day downloads, ranking snapshot 2026-07-01, surveyed 2026-07-16); see
`pypi-survey/README.md` for method and `pypi-survey/findings.md` for the full
tables, cross-referenced against the wheels this repo publishes.

## The model

Pure-python packages cost nothing per package:

- Cross builds skip the run-only phases, so a pure wheel builds through the
  nixpkgs cross stdenv untouched. A `python-packages/<attr>.nix` is only ever a
  build fix, never a prerequisite.
- The registry publishes every shipped wheel plus its transitive python deps
  (`packaging.md`), so shipping one app lands its whole pure closure.

Coverage is therefore gated entirely by native packages sitting in other
packages' closures. 85.4% of the top-10k is pure, but only 58.5% has a fully
pure closure. The gap is pure packages held hostage by one native dep, and that
gap is what a native build buys back.

A native package that also publishes a `py3-none-any` fallback wheel resolves
from PyPI like a pure one, so it never blocks either; 73 of the survey's native
packages do. Shipping one still buys speed or a real C path, but not coverage.

## Where we are

A package counts as buildable when every native package in its dependency
closure is published or resolves from PyPI:

| cutoff     | buildable | blocked |
| ---------- | --------- | ------- |
| top 100    | 100.0%    | 0       |
| top 1,000  | 95.1%     | 47      |
| top 10,000 | 84.3%     | 1,480   |

Out-of-scope packages are excluded from the denominator; see below.

The shipped native set is the registry closure, not `wheels.nix`: transitive
dependencies publish without a worklist entry. Per-package build details live in
each `pkgs/overlay/packages/<pkg>.nix` /
`pkgs/overlay/python-packages/<pkg>.nix` and the commit that added it.

## Decide what to add

```
wasinix python coverage --cutoff 10000
```

The command evaluates the current registry's served names and versions, then
ranks three independent worklists from the vendored surveys:

- pure roots whose closure is already buildable but which the registry does not
  yet publish;
- native packages in greedy order by the remaining traffic they immediately
  unblock; and
- historical versions selected by the version survey but absent from the
  registry.

`--limit` bounds each section. `--json` returns the same report for scripts. The
native section excludes closures that reach a package declared in
`pypi-survey/data/out-of-scope.json`; that file is the policy inventory for the
categories below.

Refresh the vendored inputs only when intentionally taking a new PyPI metadata
snapshot:

```
wasinix python survey refresh --cutoff 10000
```

It contacts PyPI and rewrites survey data. `python coverage` remains offline
apart from evaluating the local registry. The refresh uses the tracked traffic
ranking; update `pypi-survey/data/top.json` separately when taking a new
download snapshot.

## Recompute

Take the shipped set from every interpreter, since a `publishOnce` entry appears
under only one:

```
nix eval --json .#legacyPackages.x86_64-linux.pythonRegistry.wheels \
  --apply 'ws: builtins.concatLists (map builtins.attrNames (builtins.attrValues ws))'
```

`transitive.json` records each package's DIRECT native deps, not its closure.
`dependencies.json` is the compact full dependency graph that `transitive.py`
emits from the metadata cache, so the coverage command can rebuild closures
without fetching PyPI again.

## Burn-down

Greedy order, each build unblocking the most still-blocked packages. The head is
flat now: no remaining native package unblocks more than ~15, and most unblock
3-7, so progress is a long tail rather than a few big levers.

Budget the tail by what a package needs, not by its unblock count. Measured over
~130 attempted builds:

| shape                                     | builds                         |
| ----------------------------------------- | ------------------------------ |
| grammar or extension with no external dep | most pass                      |
| rust/pyo3 wheel                           | ~1 in 6 pass first try         |
| anything naming an external C library     | gated on that library crossing |

A wheel that upstream ships self-contained still needs its C dependency built
here, so the survey's "no bundled libs" signal describes upstream's wheel, not
this build. The recurring failure shapes, in rough order of how often they came
up:

- a build step running on the build host imports the wasm interpreter's modules
  (numpy for `get_include()`, cffi's `_cffi_backend`): add the build-host module
  to `nativeBuildInputs`, as `ml-dtypes.nix` does.
- the extension compiles against the native python headers and dies on
  `pyport.h: LONG_BIT definition appears wrong for platform`: point it at the
  cross include.
- setup.py finds a library through `pkg-config` or a `*-config` binary, so
  `buildInputs` never reaches it.
- the nixpkgs expression rejects the wasm system outright, or pulls a test-only
  dependency that does.

## Out of scope

Declared, not attempted. Roughly 3% of the top-10k. Categories include GPU and
CUDA packages, macOS frameworks, runtime JITs, and bundled toolchain or browser
payloads. The survey data owns the package inventory.

## Demand side

Unblocking a native package does not by itself publish the packages it unblocks.
They reach the registry only as the closure of something in `wheels.nix`. Two
ways to close that gap:

- Curated apps, the current model: add top-level packages, deps ride along. Good
  signal per entry, uneven coverage.
- Survey-driven worklist: generate `wheels.nix` pure entries for every top-N
  package whose native closure is already satisfied. Pure builds are cheap, so
  this is what turns the coverage percentage into an actually populated
  registry. Gate by cutoff (top-1k first) to bound CI cost.

Either way, re-run the burn-down after each native build lands: the newly
unblocked set is the next batch of pure entries.
