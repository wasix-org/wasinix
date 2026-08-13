# Building and checking

Where builds run, how to build one thing, and how to check a change before it
goes to CI.

## Where builds run

The toolchain and the full `.ci` sweep are expensive: local builds at that scale
drive the machine into swap, and a stray system-default builder (a paid
`nixbuild.net`) costs real money. Expensive builds go to a remote builder you
control.

`--builders ""` is not remote. It suppresses the configured default and then
builds locally, which is the easiest failure mode to walk into.

The builder is machine-specific, so it lives in a gitignored `.remote-builder`
(copy `.remote-builder.example`). `scripts/remote-builder.sh` turns it into
ready-made flags; never hardcode a host or key. Being gitignored it is missing
in fresh worktrees, so copy it over from another one.

```sh
scripts/remote-builder.sh check     # configured and reachable?

nix build <targets> --max-jobs 0 \
  --builders "$(scripts/remote-builder.sh builders)" --builders-use-substitutes
```

`--max-jobs 0` is required, else nix still schedules jobs onto local slots or
the system default.

## Iterate with Spot first

For a toolchain or low-level dependency change, start with
`scripts/spot.sh <profile>.<attr>`. Spot rebuilds only the targets you name and
the working-tree inputs you choose, while taking the rest from a cached base.
This can turn a world-rebuilding change into a short compile-and-link check.

Use `--dry-run` to see the cost before building. A green Spot build is useful
iteration evidence, not final verification, because its output mixes the base
and working-tree toolchains. See `docs/spot.md` for choosing the rebuild cut and
the required full-build follow-up.

## The cache and the full sweep

```sh
scripts/ci-build-remote.sh                     # signed, cache-pushing CI set; offloads eval too

nix-fast-build --flake .#legacyPackages.x86_64-linux.ci --skip-cached \
  --no-link --option accept-flake-config true \
  --store "$(scripts/remote-builder.sh store)"
```

This is the same build set as CI (`scripts/ci-build.sh`).

`--skip-cached` is what makes it survivable. It drops any job already in the
binary cache, so those cost neither a build nor a download, where a plain
`nix build` of the same target would substitute the whole closure into the local
store. On a warm cache the sweep is an eval plus whatever the change genuinely
rebuilds.

That only holds while the change avoids mass rebuilds, and those are easy to
trigger: anything under `pkgs/toolchain/` (except `llvm.nix`) rebuilds
everything, as does a pin bump.

## Let CI build it

`build.yml` runs on every pull request and builds the whole package set, each
package as its own job. So opening a PR is a legitimate way to build something
you cannot build locally, and often the cheapest one.

Results come back as a "Per-package status" check run and a sticky comment on
the PR, upserted in place by `scripts/post-report.js`, so the report stays at
one comment across pushes. Read that rather than rebuilding to find out what
broke.

## Eval is cheaper than building, not free

`nix fmt` costs nothing and a single `nix eval` is moderate, both fine locally
but not worth firing off in a loop.

nix-eval-jobs is the one to watch. It fans out `--workers` evaluators, each with
its own heap allowance (`--max-memory-size`, 4 GiB per worker by default), so
the ceiling is workers times that allowance. One worker per core over the full
`ci` set puts that in the tens of gigabytes, enough to swap or OOM a desktop.
Size workers against free RAM rather than core count, and lower the allowance
with them:

```sh
nix-eval-jobs --flake .#legacyPackages.x86_64-linux.ci --workers 4 --max-memory-size 2048
EVAL_WORKERS=4 scripts/ci-build.sh
```

`scripts/ci-build.sh` reads `EVAL_WORKERS` (default `$(nproc)`) and passes it to
both nix-eval-jobs and nix-fast-build. `ci-build-remote.sh` pins it to 8 for a
separate reason: on a shared builder the workers contend on the one nix-daemon.

## Build one thing

A CI job name is a build path. These are example targets; the final command
lists the complete set:

```sh
nix build .#packagesByProfile.exnrefEh.zlib
nix build .#wasmerPackages.git.webc
nix build .#pythonWheels.py314.numpy

nix eval .#legacyPackages.x86_64-linux.ci --apply builtins.attrNames
```

For example, toolchain suites are available at `.#toolchain.wasixcc.tests`,
`.#toolchain.sysroot.tests`, and `.#checks.x86_64-linux.rust`. Use
`nix flake show` for the current check set.

## Before you commit

- New files must be tracked. Nix reads the working tree, so uncommitted edits to
  tracked files are picked up as they are, but an untracked file does not exist
  as far as the flake is concerned. `git add -N <file>` is enough: it registers
  the path without staging its contents.
- `nix fmt`. CI rejects unformatted files, and prettier covers markdown as well
  as Nix.
- For a behaviour-preserving refactor, diff the derivations. Semantic
  equivalence is the bar, not identical drv paths, and meta or passthru changes
  do not move them at all.

  ```sh
  nix eval .#legacyPackages.x86_64-linux.ci \
    --apply 'j: builtins.mapAttrs (_: d: d.drvPath) j'
  ```

- A regression test must fail with the fix reverted. Run it both ways.
- A build that compiles is not a working package. Check the artifact does what
  it is for, and that it targets wasix.

## Diagnosing a failure

Read the log, do not rebuild to see the error again.

```sh
ssh "$(scripts/remote-builder.sh host)"
nix log <drv>
```

A failed CI job is read from the CI report. nixbuild.net returns a cached
failure link rather than a log; use the EC2 builder or
`--option reuse-build-failures false` instead of falling back to a local build.

When you do start a long build, print the logs and tee them to a file, so a
failure is diagnosable without waiting for the whole build.

## For agents

The rest of this page assumes a person at a terminal. Three things work
differently without one.

**Ask where to build before you build, once, and remember the answer.** This
page gives the general policy, but the right route depends on hardware you
cannot see: how much they want built, and whether that goes to a local machine,
a remote builder, one of several, or a PR so CI does it. Ask, then save the
answer to memory so later sessions do not ask again or guess wrong. Re-ask only
when the answer stops fitting, such as a builder that is no longer reachable.

**A long build cannot live inside a single tool call.** It will outlast the
call's timeout, and a truncated or interleaved transcript is not a log. Start it
detached, tee the full output to a stable path, and say where that path is so
the user can `tail -f` it:

```sh
nix build <targets> --max-jobs 0 \
  --builders "$(scripts/remote-builder.sh builders)" --builders-use-substitutes \
  -L > /tmp/wasinix-<what>.log 2>&1 &
```

Then poll the log rather than restarting the build. If you lose the handle, read
the log to find out where it got to; never relaunch on the assumption it died.
Watch for stalls too: judge progress by new output, and report "no output for N
minutes on <phase>" instead of waiting silently or calling it finished.

**A cached-failure link is a browser page.** nixbuild.net returns a link instead
of a log, `nix log --store ssh://...` cannot retrieve it, and WebFetch gets
nothing because the page loads its log by JS. The link nix prints already
carries a read token, and the log itself is plain HTTP at `/builds/<id>/log`:

```sh
curl -s "https://nixbuild.net/builds/<id>/log?t=<token>" | python3 -c "
import sys,re,html
s = re.sub(r'<(style|script)\b.*?</\1>', '', sys.stdin.read(), flags=re.S|re.I)
print(html.unescape(re.sub(r'<[^>]+>', '\n', s)))"
```

Strip `<style>`/`<script>` first or the page CSS lands in the output looking
like log text. This is for diagnosing without an edit in hand; a drv that
changed since the failure just builds normally.

Cap `--workers` deliberately. You cannot feel the machine swapping, but the user
can.
