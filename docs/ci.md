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
  `failures`, `watch`, `wait`, `cancel`.
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

The verdict has three values. A green run passes; a red run has a failed
required gate or a comparison with regressions; a diff whose baseline could not
evaluate concludes **neutral**, never red, because a failure the base shares is
the status quo, not a regression the change introduced.

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

## The remote builder in CI

The EC2 nix builder (`docs/building.md`) stops itself when it has been idle for
fifteen minutes: it is a 32-core box whose value is its warm store, so it is
paid for only while it builds. A workflow that wants it must start it first.

`.github/actions/wake-builder` does that in one step. It exchanges the job's
GitHub OIDC token for an AWS role, starts the instance, and returns once sshd
answers — the readiness signal that matters, since the build is an `ssh-ng`
connection. It leaves the private key and `known_hosts` on disk and names both
in its outputs, so the step that builds can point `--on` at the box.

```yaml
permissions:
  id-token: write

jobs:
  build:
    environment: nixbuilds # the role trusts this and nothing else
    steps:
      - uses: ./.github/actions/wake-builder
        with:
          role-to-assume: ${{ vars.NIXBUILDS_WAKE_ROLE_ARN }}
          instance-id: ${{ vars.NIXBUILDS_INSTANCE_ID }}
          host: ${{ vars.NIXBUILDS_HOST }}
          host-key: ${{ vars.NIXBUILDS_HOST_KEY }}
          ssh-key: ${{ secrets.NIXBUILDS_SSH_KEY }}
```

`environment: nixbuilds` is the access control, not a label. The role in AWS
trusts exactly one subject — `repo:wasix-org/wasinix:environment:nixbuilds` —
so a job without that line cannot assume it whatever branch it runs on, and a
fork pull request cannot at all, because forks are never issued an OIDC token.
Anything put on the environment as a required reviewer therefore gates the
builder too.

No AWS key is stored anywhere, and the role can do exactly one thing:
`ec2:StartInstances` on that single instance. It cannot look the machine up,
which is why the address is configuration here — the box holds an Elastic IP
and keeps it across stops.

`wake-builder.yml` runs the same step on `workflow_dispatch` and reports what
woke up. Use it to check the path, or to warm the box before a session.

Three of the four `vars` come from `infrastructure/aws/clusters/aux`:
`terraform output -json nixbuilds_wake` prints the role ARN, the instance id
and the host. `NIXBUILDS_HOST_KEY` is the builder's own public key, read off
the box (`ssh-keyscan` against it once, or `/etc/ssh/ssh_host_ed25519_key.pub`);
omitting it makes the first connection trust whatever key answers.
`NIXBUILDS_SSH_KEY` is the private key the builder accepts, and is the one
value that belongs in secrets rather than vars.
