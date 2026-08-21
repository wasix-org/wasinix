# CI and the orchestrator

The `wasinix` binary (`tools/wasinix`) is the one tool: it builds, diffs,
bisects, updates pins, serves the registries, and runs CI. The GitHub workflows
are thin adapters that call it. This page is the map; each command's `--help` is
the reference.

## The command tree

Verbs act on the tree, nouns have lifecycles:

- `build <selectors>` builds CI sets, groups, or job addresses.
- `spot <targets>` rebuilds attrs over a cached base (`docs/spot.md`).
- `diff <case> --vs <case>` compares two complete build or spot cases; the first
  is the baseline.
- `bisect <target> --good --bad -- <predicate>` finds the dependency commit that
  first breaks a build or spot predicate.
- `update` and `versions` maintain pins and the served-version tables
  (`docs/updating.md`).
- `run` owns durable runs: `start`, `list`, `status`, `logs`, `report`,
  `failures`, `watch`, `wait`, `cancel`, `pin`, `unpin`, `gc`.
- `remote` inspects the configured builders: `list`, `status`, `doctor`,
  `field`, `init`.
- `cargo`, `wasmer`, and `python` are the three registries, each with
  `serve`/`publish`/`preview` (`docs/registry.md`, `docs/rust.md`).
- `ci` is the adapter surface the workflows call: `run`, `prepare`, `exec`,
  `publish`, `origin`, `command`, `remote`, `observe`. Hidden from the top-level
  help; not for interactive use.

Every expensive verb takes `--on local | <remote> | <remote>:<route>`; the
document-producing commands (`run list|status|report|failures`, `update list`,
`remote list`, `cargo publish`, the build verbs) take `--json`;
`-v`/`-q`/`--color` are global.

## What a run produces

A run is one directory. `prepare` resolves the request into it (materialized
cases, `request.json`, `preparation.json`); `exec` walks the plan, and each task
leaves a typed fragment. The report is folded from the fragments by
`ci/report.rs` and nowhere else, so the terminal verdict, `run failures`, the
markdown comment, and the check summary describe the same facts.

Tasks do work and emit facts; anything computable from persisted facts is a
projection the fold derives. The diff comparison is the example: no task
computes it, `ci/compare.rs` projects it from the case directories each time the
fold runs, so its eval half (added, removed, version moves, rebuilds) reaches
the comment as soon as both evaluations exist and its build half (regressions,
fixes) joins when results land.

Progress is an append-only `events.jsonl`; the snapshot is derived from it, not
maintained beside it. Every progress view (the terminal ladder, `run watch`,
`run logs --follow`, a remote observer) replays that one stream.

The verdict has four values. A green run passes; a red run has a failed
required gate or a comparison with regressions. Removed jobs stay in the
comparison for reviewer information but do not fail it. A diff whose baseline
could not evaluate concludes **neutral**, never red, because a failure the base
shares is the status quo, not a regression the change introduced. A selection
whose jobs could not run because dependencies failed concludes **blocked**.
Build, spot, diff, and bisect accept `--blocked=fail|skip|good` (default
`fail`) to map that result to the process, check-run, and bisect outcome; the
report still says blocked under every policy. A directly selected failure is
always red.

## Where the time went

A run directory dies with its runner, so the times a main build measures are
published: per-job build seconds and per-task wall time ride the eval map
(`eval-maps/<tree>.json`, keyed by git tree), and the workflow's own step
durations go to `step-timings/<rev>.json`.

```sh
wasinix timings --runs 100 [--by job|task|step|rev]
wasinix timings [<range>] [--by job|task|step|rev]
```

`--runs` folds the revisions CI actually ran on, from the workflow's own run
list. That is the form to reach the work: a rebase-merge gives a landed pull
request a new sha, so its run's head is an ancestor of no branch, and the builds
that cost anything happen there and in the merge queue rather than on main. A
range folds a branch's own commits instead, defaulting to `HEAD~20..HEAD`.

Either way the keys derive from what is being folded, so no bucket listing is
needed. Each row carries the total, how many runs measured it, and the first and
last value, since a mean hides a regression. Revisions that published nothing
are a gap, and the header says how many were measured.

`--by job` finds the package that grew, `--by task` the pipeline phase,
`--by step` the setup cost, and `--by rev` answers whether CI as a whole is
getting slower.

## Durable and remote runs

`run start -- <command>` detaches a supervisor that is the only writer of
`run.json`, so no observer can clobber a recorded exit. The run survives the
terminal; a supervisor that dies without recording an exit reads as `lost`.
Cancel writes a marker file; the supervisor terminates the payload's process
group (KILL after a grace period).

`--on <remote>:host` ships the checkout and supervises the run on the builder,
which runs it as its own durable run; the local side tails the remote
`events.jsonl` and fetches the finished run. Losing the observer never loses the
run, and `ci observe` re-attaches. The launch prints a `<remote>:<run>` handle,
which `run cancel` accepts. The remote supervisor holds one of the builder's
`capacity` slots for the run's whole life, so concurrent launches from different
machines cannot overcommit the host.

`run gc` combines explicit `--max-age-days`, `--max-count`, and `--max-bytes`
limits. It never collects a recorded active run or one protected by `run pin`;
`--dry-run` and `--json` expose the same selection without deleting it. There
is no implicit retention limit.

## GitHub

`build.yml` runs one CI run per event and publishes through `ci publish`: the
sticky "Wasinix CI" comment and check run on same-repo events, the step summary
as the overflow home. While the run executes, `ci publish --watch` tails the
same event stream and republishes the comment and check at most every five
minutes; the finished surfaces still come only from the post-run publish.
`test-report.yml` re-publishes fork PRs in base context (the PR's read-only
token cannot post in-job); a fork's report is its own code's claim, so it
publishes `--untrusted` and concludes neutral.

`ci-command.yml` handles `/wasinix <command>` on a pull request: `ci origin`
authorizes it (the shared grammar, a live write-permission check, PR state),
`ci command` runs it, and the reply is keyed to the commenting comment. Every
malformed or unauthorized command gets a reply.

`--plan` resolves the request and replies with its pinned request and task
list from the authorization job. It does not start a durable run or enter the
report publisher, because no build tasks or report exist.

`/wasinix bisect <target> --good <ref> --bad <ref> -- build <selectors>` runs on
the runner like every other comment command, so its predicate is a case pinned
there and it cannot name a builder. `--reverse` asks the other question, where
the predicate started passing, so `--bad` names the older failing revision and
`--good` the newer passing one. The runner's job limit is smaller than a long
bisect, so a comment bisect carries a budget: it stops with the range narrowed,
replies with what it tested, and the same command again resumes from the
recorded outcomes. `/wasinix fmt` formats the branch and commits the result,
serialized per PR with the other mutations.

Every command comment runs its own workflow: acknowledged, authorized, and
answered even in a burst, and builds run in parallel, each replying to its own
comment (the PR's required check stays build.yml's). Mutations rewrite shared
branch state, so they serialize per PR: of a mutation burst the first and the
latest run, and one replaced while queued gets a superseded reply.

Untrusted text (build logs, junit messages, PR comment bodies) passes exactly
one sanitizer at the render edge: fences sized past the payload, HTML and cell
escaping that neutralizes line breaks and backslashes. A managed surface is one
marked comment, upserted by an author-checked first-match lookup, so a marker
planted in someone else's comment is never adopted.
