# Building and checking

Where builds run, how to build one thing, and how to check a change before it
goes to CI.

Every command here is the `wasinix` CLI: on PATH in a dev shell, and
`nix run .#wasinix -- <args>` without one.

In a consuming flake, expose `wasinix.lib.appsForProject` and use the same
commands. `--project FLAKE#PROJECT-ATTR` selects a project explicitly; generated
apps bind it automatically.

## Where builds run

The toolchain and the full CI sweep are expensive: local builds at that scale
drive the machine into swap, and a stray system-default builder (a paid
`nixbuild.net`) costs real money. Expensive builds go to a remote builder you
control.

`build` and `spot` take `--on` to choose where their expensive work runs:
`--on local` here, `--on <remote>` on a configured builder, or
`--on <remote>:<route>` to pick the route (`builder`, `store`, or `host`). Build
and spot cases inside `diff` and `bisect` use the same option. Absent, it uses
the configured default remote. `wasinix remote list` shows what is configured;
`wasinix remote doctor` verifies one. Builders live in `builders.toml`
(`$XDG_CONFIG_HOME/wasinix/`), never in the flake; `wasinix remote init` writes
a commented template.

```sh
wasinix remote list
wasinix remote doctor --ifd     # connectivity, store, and an IFD round trip
wasinix build all --on ec2      # the whole set on the ec2 builder
```

## Iterate with spot first

For a toolchain or low-level dependency change, start with
`wasinix spot <profile>.<attr>`. Spot rebuilds only the targets you name and the
working-tree inputs you choose, taking the rest from a cached base. This can
turn a world-rebuilding change into a short compile-and-link check.

`--plan` resolves the splice and reports the build counts before building. A
green spot build is iteration evidence, not final verification, because its
output mixes the base and working-tree toolchains. See `docs/spot.md` for
choosing the rebuild cut and the required full-build follow-up.

## The full sweep

`wasinix build all --on <remote> --push-cache` builds the whole CI set and, with
a signing key present, pushes completed work to the cache the GitHub builders
consume. Running it before CI warms the PR build. Store paths are
input-addressed and baselines are keyed by the materialized git tree, so every
keyed run pushes what it builds and no run can publish under a key it did not
produce. The pinned formatting check always runs locally; routing its tiny build
remotely would transfer the whole source closure before doing a few seconds of
work.

Work built without `--push-cache` is pushed retroactively by
`wasinix cache push [selectors]`: it reuses the working tree's recorded
evaluation (evaluating locally when none exists), skips what the cache already
holds, and needs `NIX_SIGNING_KEY`. If you hold the key, push what you built:
the next CI run substitutes instead of rebuilding, which saves billable runner
minutes and everyone's queue time.

Cached jobs are skipped for you by the build driver's dry-run plan: a job
already in the cache costs neither a build nor a download. On a warm cache the
sweep is an eval plus whatever the change genuinely rebuilds. That only holds
while the change avoids mass rebuilds, which are easy to trigger: edits to the
native compiler, sysroot, stdenv, or language-platform construction rebuild most
of the catalog, as does a pin bump.

## Let CI build it

`build.yml` runs on every pull request and builds the whole package set, each
package as its own job. Opening a PR is a legitimate way to build something you
cannot build locally, and often the cheapest one.

Results come back as one "Wasinix CI" check run and a sticky comment on the PR,
upserted in place across pushes. Read that rather than rebuilding to find out
what broke. On the PR you can also run `/wasinix build <selectors>` in a
comment; the same command grammar the terminal uses parses there, behind a
write-permission check.

## Eval is cheaper than building, not free

`nix fmt` costs nothing and a single `nix eval` is moderate. nix-eval-jobs is
the one to watch: it fans out `--workers` evaluators, each with its own heap
allowance (`--max-memory-size`, 4 GiB per worker by default), so the ceiling is
workers times that allowance. The CI set needs more than the default; reaching
it restarts the worker and discards its state, which reads as a slow eval that
never finishes. Size workers against free RAM, not core count, and set the
budget through the environment the CLI reads:

```sh
WASINIX_EVAL_WORKERS=2 WASINIX_EVAL_MEMORY=16384 wasinix build all --on local
```

The build tail's parallelism is a separate knob: `WASINIX_MAX_JOBS` caps
concurrent derivations for a local build (default: every core). Persistent local
limits, including a `capacity` bounding concurrent local runs, live in the
`[local]` table of `builders.toml`; the environment overrides them per
invocation, and remote builders carry their own limits in their profiles.

## CLI Rust rebuilds

The host CLI has three independent Crane nodes: cached Cargo dependencies, the
production binary, and repository-aware unit tests. Rust source changes rebuild
the binary and tests in parallel without recompiling dependencies. Changes to
test fixtures rebuild only the tests. `Cargo.lock` changes invalidate all three.
The package and test units expose this one graph from
`pkgs/overlays/w/wasinix/build.nix`; do not create a second Rust recipe in a
test unit.

The split was measured on the configured 32-core EC2 builder on 2026-08-26. With
the Rust outputs absent, the dependency, binary, and test work took 71 seconds;
that first test run exposed an omitted fixture, and the corrected test-only node
then passed in 30 seconds. From the passing graph, a Rust-source change rebuilt
binary and tests in 31 seconds, a fixture-only change rebuilt tests in 30
seconds, and a lock-file change rebuilt all three in 60 seconds. The
measurements exclude the repository's Nix evaluation and closure transfer.

## Build one thing

A CI job name is a build path. `wasinix jobs <pattern>` searches the addresses
recorded by the last evaluation, with no evaluation of its own:

```sh
wasinix jobs hydra              # every address with a hydra segment
wasinix jobs 'checks.wheel*'    # segment globs, as in build selectors

nix build .#legacyPackages.x86_64-linux.packages.wasix.exnrefEh.zlib
nix build .#legacyPackages.x86_64-linux.artifacts.webc.git
nix build .#legacyPackages.x86_64-linux.artifacts.wheel-py314.numpy
```

`wasinix build <selectors>` runs the same job through the orchestrator, which
also warms inputs, evaluates, and folds a report; a bare `nix build` is fine for
one target.

## Before you commit

- New files must be tracked. Nix reads the working tree, so uncommitted edits to
  tracked files are picked up, but an untracked file does not exist as far as
  the flake is concerned. `git add -N <file>` registers the path without staging
  its contents.
- `nix fmt`. CI rejects unformatted files, and prettier covers markdown as well
  as Nix.
- `nix flake check`. This runs formatting, Nix linters, and project-API
  evaluation tests; package and runtime builds belong to `wasinix build`.
- For a behaviour-preserving refactor, diff the derivations. Semantic
  equivalence is the bar, not identical drv paths; meta or passthru changes do
  not move them at all.

  ```sh
  nix eval .#legacyPackages.x86_64-linux.ci.jobs \
    --apply 'j: builtins.mapAttrs (_: d: d.drvPath) j'
  ```

- A regression test must fail with the fix reverted. Run it both ways.
- A build that compiles is not a working package. Check the artifact does what
  it is for, and that it targets wasix.

## Diagnosing a failure

Read the log, do not rebuild to see the error again. `wasinix run failures <id>`
lists a run's failures with the archived-log path for each;
`wasinix run logs <id>` prints the run log. For a bare drv:

```sh
nix log <drv>
```

A failed CI job is read from the CI report. nixbuild.net returns a cached
failure link rather than a log; use the EC2 builder or
`--option reuse-build-failures false` instead of falling back to a local build.

## For agents

The rest of this page assumes a person at a terminal. Three things work
differently without one.

**Read the configured routes before you build.** `wasinix remote list` presents
each remote's intended workload, availability, and constraints. The user's
gitignored `AGENTS.override.md` can override the repository default for their
own infrastructure. Ask only when neither answers whether the work should go
locally, to a remote builder, or to CI; re-ask when the configured route no
longer fits, such as a builder that is unreachable.

**A long build cannot live inside a single tool call**, and it must not be a raw
`... &`. Start it as a durable run and inspect the run record, which is
authoritative; do not infer state from `ps` or a tool-call timeout.

```sh
id=$(wasinix run start -- wasinix build all --on ec2 --push-cache)
wasinix run status "$id" --json     # state + progress snapshot
wasinix run watch "$id"             # narrate the event stream
wasinix run wait "$id" --timeout 60 # bounded observation; the run keeps going
```

`run start` executes its payload verbatim, so a wasinix payload names the
binary. It detaches a supervisor; the run survives your terminal, `run watch`
and `run logs --follow` replay the same event stream, and joining mid-run shows
the completed phases' receipts first. A run whose supervisor died without
recording an exit reads as `lost`, a state like any other, not a hang.

To offload the whole thing to a builder host, `--on <remote>:host` ships the
checkout and supervises the run on the host; `wasinix ci observe` re-attaches to
it, and losing the observer never loses the run.

**Local cargo builds of the crate need the host toolchain.** The dev shell
exports the wasix cross toolchain as `CC`/`CXX`/`AR`, so a cargo dependency's
host build script compiles wasm objects and the host link fails with "archive
member ... neither ET_REL nor LLVM bitcode". Build the `tools/wasinix` crate
with `CC_x86_64_unknown_linux_gnu=cc AR_x86_64_unknown_linux_gnu=ar` set (nix
builds are unaffected). If the ring objects were already poisoned,
`rm -rf target/debug/build/ring-* target/debug/deps/libring-*` before
rebuilding.

Cap `--workers` deliberately. You cannot feel the machine swapping, but the user
can.
