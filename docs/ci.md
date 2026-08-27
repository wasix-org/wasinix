# CI and the orchestrator

The `wasinix` binary (`tools/wasinix`) is the one tool: it builds, diffs,
bisects, updates pins, serves the registries, and runs CI. The GitHub workflows
are thin adapters that call it. This page is a map of the command families;
`wasinix --help` and each command's `--help` are the complete reference.

## The command tree

Verbs act on the tree, nouns have lifecycles:

- `doctor` reports first-run configuration and `jobs` searches the remembered
  job catalog.
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
- `cache` pushes cached outputs, and `timings` reports CI cost across revisions.
- `cargo`, `wasmer`, and `python` are the three registries, each with
  `serve`/`publish`/`preview` (`docs/registry.md`, `docs/rust.md`).
- `publish`, `preview`, and `serve` operate across registry families.
- `completions <shell>` generates shell completion registration.
- `ci` is the adapter surface the workflows call: `start`, `run`, `prepare`,
  `exec`, `publish`, `origin`, `command`, `remote`, `observe`. Hidden from the
  top-level help; not for interactive use.

`build` and `spot` take `--on local | <remote> | <remote>:<route>`; build and
spot cases inside `diff` and `bisect` use the same option. Commands that render
structured reports expose `--json`; `-v`/`-q`/`--color` are global.

## Catalog and selection

Nix publishes facts; the CLI owns selection semantics. The structured project
provides `ci.jobs`, a canonical-address-to-derivation map, and
`ci.catalog.jobs`, serializable metadata for exactly the same keys. It also
publishes factual selector sets and groups, such as which jobs belong to the
Python set or which package owners make up the C toolchain group.

The CLI checks `schemaVersion` before interpreting those facts. It resolves
aliases, omitted profile axes, globs, named sets and groups, unions, and tag
gates, then requests the exact resulting job addresses from Nix in one batch.
The evaluation-input phase persists the selector catalog and authoritative job
evaluation reads that file, so a case evaluates the catalog only once.
Historical jobs remain cataloged and are tagged `history-tests`; selecting one
without enabling that tag is an error rather than a silent omission.

`source=<extension-id>` filters any selection to jobs owned by that source's
package closure. A source filter by itself implies `all`, so these are
equivalent:

```sh
wasinix build source=my-project
wasinix build all source=my-project
```

Artifacts and tests attached to the source's packages remain selected even when
their projection rule comes from another extension.

This division lets extension flakes contribute ordinary catalog entries and CI
facts without reimplementing selector behavior in Nix. It also keeps the
orchestrator's errors and selection rules identical for this repository and for
external Wasinix projects.

## What a run produces

A run is one directory. `prepare` resolves the request into it (materialized
cases, `request.json`, `preparation.json`); `exec` walks the plan, and each task
leaves a typed fragment. The report is folded from the fragments by
`ci/report.rs` and nowhere else, so the terminal verdict, `run failures`, the
markdown comment, and the check summary describe the same facts.

Tasks do work and emit facts; anything computable from persisted facts is a
projection the fold derives. The diff comparison is the example: no task
computes it, `ci/compare.rs` projects it from the case directories each time the
fold runs. Added, removed, and version changes compare the complete catalogs;
rebuilds, regressions, and fixes compare the jobs selected on both sides. The
report states selected, tag-omitted, and outside-selector coverage separately,
so disabling a tag cannot look like removing a job. The catalog half reaches the
comment as soon as both evaluations exist, and build outcomes join when results
land.

Progress is an append-only `events.jsonl`; the snapshot is derived from it, not
maintained beside it. Every progress view (the terminal ladder, `run watch`,
`run logs --follow`, a remote observer) replays that one stream. Case
materialization, baseline reuse, and plan generation appear there before the
first build task starts. A phase start records its name and time, so a quiet
tool still renders as the active phase with increasing elapsed time.

Task diagnostics live on their fragments regardless of task kind. The fold
deduplicates shared diagnostics and their affected jobs into the report; final
terminal and GitHub surfaces render that report instead of re-reading task
facts.

A blocked build task records the shortest derivation path from each selected job
to every failed dependency root. It reads the direct-input graph once, so the
comment can distinguish the selected job, intermediate dependencies, and the
failure whose log and reason explain the result.

Task and durable-run transcripts retain at most 64 MiB each by default: their
opening context and newest output, with the omitted byte count between them. A
neighboring `*.retention.json` records original and retained bytes. Set
`WASINIX_LOG_BYTES` to a positive byte limit when a runner needs another cap.
`run status` and `run report` aggregate those facts into log count and produced,
retained, and omitted bytes; the JSON and human output use the same summary.
When a run finishes, its completed transcripts are compacted fairly to 256 MiB
in total. Small transcripts remain whole before larger ones share the remaining
space. `WASINIX_RUN_LOG_BYTES` sets another positive byte limit for the run.

Each task boundary also records the total and available space on the filesystem
backing `/nix/store`. Nix automatic-GC announcements record how many times it
ran and how many bytes it requested; that request is not reported as bytes
reclaimed. `run report --json` carries the per-task samples and aggregate store
low-water mark, while `run report -v` renders the same measurements.

The verdict has four values. A green run passes; a red run has a failed required
gate or a comparison with regressions. Removed jobs stay in the comparison for
reviewer information but do not fail it. A diff whose baseline could not
evaluate concludes **neutral**, never red, because a failure the base shares is
the status quo, not a regression the change introduced. A selection whose jobs
could not run because dependencies failed concludes **blocked**. Build, spot,
diff, and bisect accept `--blocked=fail|skip|good` (default `fail`) to map that
result to the process, check-run, and bisect outcome; the report still says
blocked under every policy. A directly selected failure is always red.

## Where the time went

A run directory dies with its runner, so the times a main build measures are
published: per-job build seconds and per-task wall time ride the eval map
(`eval-maps/<tree>.json`, keyed by git tree), and the workflow's own step
durations go to `step-timings/<rev>.json`. Successful main builds also attach
the update snapshot described in [`updating.md`](updating.md); pull requests do
not pay for that projection.

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

A followed run log remains append-only. If its rolling tail begins replacing
older output, the follower sees a retention marker immediately and receives the
retained newest output when the command ends.

`run gc` combines explicit `--max-age-days`, `--max-count`, and `--max-bytes`
limits. It never collects a recorded active run or one protected by `run pin`;
`--dry-run` and `--json` expose the same selection without deleting it. There is
no implicit retention limit. Ephemeral workflow runners collect final runs only
after their report or run-directory artifact is durable; failed command runs
keep their directory until its artifact upload succeeds.

## GitHub

Workflow step outputs go through `github/actions.rs`: it rejects line breaks in
scalar values and owns the output and artifact names shared with workflow YAML.
`ci start` returns a durable run id and directory together. `ci pull-request`
resolves an exact workflow head to at most one open pull request, constrained by
both the head repository and commit. `ci preview-context` applies the preview
label, same-repository, live-head, and green-Build gates for both preview
trigger shapes.

`build.yml` runs one CI run per event and publishes through `ci publish`: the
sticky "Wasinix CI" comment and check run on same-repo events, the step summary
as the overflow home. The run checks the candidate repository source once before
evaluating its jobs, so formatting or lint failures use the same logs and
surfaces as build failures. While the run executes, `ci publish --watch` tails
the same event stream and republishes the comment and check at most every five
minutes; the finished surfaces still come only from the post-run publish.
`test-report.yml` re-publishes fork PRs in base context (the PR's read-only
token cannot post in-job); a fork's report is its own code's claim, so it
publishes `--untrusted` and concludes neutral.

`ci-command.yml` handles `/wasinix <command>` on a pull request: `ci origin`
authorizes it (the shared grammar, a live write-permission check, PR state),
`ci command` runs it, and the reply is keyed to the commenting comment. Every
malformed or unauthorized command gets a reply.

`--plan` resolves the request and replies with its pinned request and task list
from the authorization job. It does not start a durable run or enter the report
publisher, because no build tasks or report exist.

`/wasinix bisect <target> --good <ref> --bad <ref> -- build <selectors>` runs on
the runner like every other comment command, so its predicate is a case pinned
there and it cannot name a builder. `--reverse` asks the other question, where
the predicate started passing, so `--bad` names the older failing revision and
`--good` the newer passing one. The runner's job limit is smaller than a long
bisect, so a comment bisect carries a budget: it stops with the range narrowed,
replies with what it tested, and the same command again resumes from the
recorded outcomes. Each candidate also records the predicate's typed failures,
diagnostics, and dependency paths, so the final boundary commit says what made
the predicate change. Its final report uses the ordinary CI failure projection
and publishes the boundary candidate's archived failure logs. `/wasinix fmt`
formats the branch and commits the result, serialized per PR with the other
mutations.

Every command comment runs its own workflow: acknowledged, authorized, and
answered even in a burst, and builds run in parallel, each replying to its own
comment (the PR's required check stays build.yml's). Mutations rewrite shared
branch state, so they serialize per PR: of a mutation burst the first and the
latest run, and one replaced while queued gets a superseded reply.

A command reply keeps its parsed command identity and canonical `/wasinix`
command from its first live update through its final result. A red result means
the command completed and found failing checks; an internal execution failure is
labeled `internal error` instead. Finding the first bad commit is therefore a
successful bisect result, while ENOSPC or a crashed process is an execution
error.

Untrusted text (build logs, junit messages, PR comment bodies) passes exactly
one sanitizer at the render edge: fences sized past the payload, HTML and cell
escaping that neutralizes line breaks and backslashes. A managed surface is one
marked comment, upserted by an author-checked first-match lookup, so a marker
planted in someone else's comment is never adopted.
