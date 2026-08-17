# Building and checking

Where builds run, how to build one thing, and how to check a change before it
goes to CI.

## Where builds run

The toolchain and the full CI sweep are expensive: local builds at that scale
drive the machine into swap, and a stray system-default builder (a paid
`nixbuild.net`) costs real money. Expensive builds go to a remote builder you
control.

The `--on` axis chooses where every expensive verb runs: `--on local` here,
`--on <remote>` on a configured builder, or `--on <remote>:<route>` to pick the
route (`builder`, `store`, or `host`). Absent, it uses the configured default
remote. `wasinix remote list` shows what is configured; `wasinix remote doctor`
verifies one. Remotes live in `remotes.toml` (`$XDG_CONFIG_HOME/wasinix/`),
never in the flake; `wasinix remote init` writes a commented template.

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
produce.

`--skip-cached` is applied for you by the underlying nix-fast-build: a job
already in the cache costs neither a build nor a download. On a warm cache the
sweep is an eval plus whatever the change genuinely rebuilds. That only holds
while the change avoids mass rebuilds, which are easy to trigger: anything under
`pkgs/toolchain/` (except `llvm.nix`) rebuilds everything, as does a pin bump.

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
WASINIX_EVAL_WORKERS=4 WASINIX_EVAL_MEMORY=8192 wasinix build all --on local
```

## Build one thing

A CI job name is a build path. These are example targets; the last command lists
the complete set:

```sh
nix build .#packagesByProfile.exnrefEh.zlib
nix build .#wasmerPackages.git.webc
nix build .#pythonWheels.py314.numpy

nix eval .#legacyPackages.x86_64-linux.ci --apply builtins.attrNames
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
- For a behaviour-preserving refactor, diff the derivations. Semantic
  equivalence is the bar, not identical drv paths; meta or passthru changes do
  not move them at all.

  ```sh
  nix eval .#legacyPackages.x86_64-linux.ci \
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

**Ask where to build before you build, once, and remember the answer.** The
right route depends on hardware you cannot see: how much they want built, and
whether that goes to a local machine, a remote builder, one of several, or a PR
so CI does it. Ask, then save the answer to memory. Re-ask only when it stops
fitting, such as a builder that is no longer reachable.

**A long build cannot live inside a single tool call**, and it must not be a raw
`... &`. Start it as a durable run and inspect the run record, which is
authoritative; do not infer state from `ps` or a tool-call timeout.

```sh
id=$(wasinix run start -- build all --on ec2 --push-cache)
wasinix run status "$id" --json     # state + progress snapshot
wasinix run watch "$id"             # narrate the event stream
wasinix run wait "$id" --timeout 60 # bounded observation; the run keeps going
```

`run start` detaches a supervisor; the run survives your terminal, `run watch`
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
