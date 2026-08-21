# Wasinix CLI consolidation plan

This plan brings the orchestrator back to one implementation per concern while
fixing its correctness, responsiveness, observability, and build-graph costs.
The stable architecture contract remains in [`architecture.md`](architecture.md)
and [`ci.md`](ci.md). This document owns the migration order and its completion
criteria.

## Outcomes

The completed CLI has:

- one command grammar for terminal, pull-request comment, and workflow use;
- explicit surface and effect policies derived from that grammar;
- one outcome model from task execution through reports, process exits, and
  bisect;
- one external-command runner and one typed capability resolver;
- a small default runtime closure, with uncommon tools realised through the
  locked flake only when needed;
- structured progress from request preparation through publication;
- bounded logs and run-state retention;
- incremental state reduction and artifact accounting; and
- structural enforcement for the boundaries above.

The migration is not a general rewrite. Each phase replaces one repeated rule,
migrates all its consumers, and deletes the superseded implementations in the
same change.

## Build-graph boundary

The main CLI is host-side control-plane software. Logic called from a
foundational derivation does not belong in that binary, because an unrelated
CLI edit would then invalidate every derivation above it.

Classify each helper before changing its language or location:

| Kind | Owner | Dependency rule |
| --- | --- | --- |
| Host orchestration | `tools/wasinix` | May use the main CLI |
| Foundational build helper | A narrowly sourced helper derivation | Must not depend on the main CLI |
| Leaf build helper | The package or final aggregate that consumes it | May affect only that leaf's closure |

A dedicated helper may remain shell or Python when that is the smallest clear
implementation. A Rust helper has its own source boundary and, when sharing the
CLI lock file would cause broad invalidation, its own crate and lock file.

An evaluated derivation-graph check protects nominated foundational roots from
direct or transitive dependencies on `wasinix` or `wasinix-core`. Legitimate
leaf exceptions are named explicitly. Source filtering also ensures that a CLI
presentation change cannot alter a helper derivation's source hash.

## One grammar and three surfaces

There is one Clap command tree and one typed command AST. Delete the parallel
untrusted command structs after their consumers use it.

Every command, positional argument, and option has an exhaustive availability
classification:

- `terminal`: public interactive use;
- `comment`: an untrusted `/wasinix` pull-request command; and
- `ci`: trusted workflow adapter plumbing.

The entry point supplies the active surface. A user cannot select a more
privileged surface with a flag.

The grammar builder returns both the Clap tree and its surface policy. The same
policy:

- validates arguments that came from the command line;
- annotates help with `terminal only`, `comment only`, or `CI only`;
- produces pull-request comment help;
- filters or annotates completions; and
- renders an unavailable argument as a specific cross-surface error.

Surface policy is exhaustive and fail-closed. A test walks the complete Clap
tree and fails for an unclassified node, a policy entry naming no node, or a
new comment-visible option without an explicit classification.

Availability and applicability are separate. An option such as
`--inputs-only` exists only on commands where it has meaning. It is not placed
on other commands and rejected later.

After parsing, the typed command derives its required effects. Surface policy
answers whether a spelling is available; effect policy answers whether the
request may perform its requested reads, writes, execution, publication, or
mutation. Comment authorization operates on this normal AST rather than a
second parser.

## Outcome model

Blocked execution remains distinct from success, failure, and comparison
neutrality. The persisted request carries:

```text
--blocked=fail|skip|good
```

The default is `fail`.

| Policy | Direct command | Bisect | Report |
| --- | --- | --- | --- |
| `fail` | Fails | Bad or error | Blocked, rejected |
| `skip` | Returns an accepted skipped result | Skip | Blocked, skipped |
| `good` | Returns an accepted result | Good | Blocked, accepted as good |

The policy applies only when every unsuccessful selected job is transitively
blocked. Any direct selected failure fails, including a mixture of direct and
blocked failures. Neither `skip` nor `good` renders blocked work as green.

Task outcomes remain facts. GitHub conclusions, shell exit codes, and bisect
outcomes are explicit projections selected at their respective boundaries.
There is no general mapping from neutral to process success.

## External commands and capabilities

One execution engine owns every child process lifecycle:

- program or typed capability;
- arguments, working directory, and environment;
- inherited, captured, or streamed I/O;
- timeout, cancellation, and child reaping;
- start, activity, completion, and elapsed-time events;
- exit classification; and
- bounded diagnostics with stream identity.

Domain modules still construct Nix, Git, OpenSSH, and registry operations. They
delegate execution instead of defining another logging and error policy.

Uncommon external programs are typed capabilities. Their installables are
constants resolved against the trusted orchestrator checkout and its
`flake.lock`. Untrusted input cannot name a flake reference, package, or output.

The initial capability candidates are AWS CLI, rclone, Python, and Wasmer.
Nix, `nix-eval-jobs`, Git, and OpenSSH remain external system boundaries unless
later evidence justifies changing one. Small deterministic shell and Python
transformations are translated according to the build-graph boundary above.

The resolver builds the required helper output without linking it into the
main CLI closure, memoises the resulting executable path for the process, and
records the flake, derivation, output, duration, and transfer data. A missing
capability and a tool execution failure are different errors.

## Minimal closure and on-demand tools

Export a minimal `wasinix-core` containing the main binary and unavoidable
linked libraries. It must not contain store references to optional capability
outputs. Keep a full convenience package during migration, but switch command
authorization, help, and error replies to the core package first.

Capability wrappers are separate flake outputs. Realising one uses the trusted
locked flake and an exact output executable. One capability does not pull the
others.

The full CLI may continue to offer convenience wrappers, but command-specific
packages do not inherit the full runtime closure. Packaging tests pin each
wrapper's declared capabilities to the commands that can request them.

## Capability prewarming

After parsing, a command derives a conservative set of anticipated
capabilities. The resolver may start one owned, batched Nix realisation while
authorization, planning, or materialisation continues.

Prewarming obeys these rules:

- only typed capabilities may be anticipated;
- one process owns and deduplicates the batch;
- the process is awaited, cancelled, and reaped;
- an unused failed prewarm does not fail the request;
- first use awaits the same work rather than starting another build;
- speculation does not trigger an unexpected local build or compete with the
  requested workload; and
- metrics distinguish anticipated, needed, unused, and ready-at-first-use
  capabilities.

Start with small, frequently needed, reliably substituted outputs. Expand the
set only when measurements show useful latency hiding without material unused
downloads.

## Events, reports, and logs

Preparation is part of the run. Materialising revisions, applying overrides,
fetching baselines, resolving capabilities, generating the plan, executing
tasks, and publishing results all emit structured phase events.

The append-only event stream is the durable history. The tracker maintains its
current snapshot incrementally and performs a full fold only when loading or
recovering a stream. Reports project persisted facts; they do not reconstruct
progress from an unstructured log tail.

Every artifact writer accounts for the bytes it owns. Execution does not scan
the complete growing run directory before and after each phase.

Logs have both live and retained limits:

- a per-log byte budget;
- a per-run aggregate budget;
- streaming parsing independent of retained bytes;
- bounded head or tail data appropriate to the diagnostic;
- compressed failure archives;
- recorded original bytes, retained bytes, and truncation; and
- structured command metadata outside the raw transcript.

Choose numeric budgets from measured successful and failing run distributions.
Post-run cleanup cannot replace live bounds, because it cannot prevent a
running job from exhausting its runner.

Successful runs discard raw data that no report or diagnostic references.
Failed runs retain bounded evidence through publication. `wasinix run gc`
supports age, count, and total-byte policies, never removes active or pinned
runs, and reports what it removed. Workflow cleanup runs only after required
reports and artifacts are durable.

## Duplication convergence ledger

Each row is complete only when all consumers use the owner and the displaced
implementations are gone.

| Concern | Owner after migration | Enforcement |
| --- | --- | --- |
| Command grammar | One Clap tree and command AST | Exhaustive surface-policy walk |
| Command applicability | Command-specific argument types | Type layout and help tests |
| Authorization | Surface policy plus derived effects | Default-deny effect checks |
| Task and command outcomes | One outcome model | Exhaustive boundary projections |
| Child processes | One execution engine | Raw starts private to its module |
| Optional programs | Typed capability resolver | Closed enum and packaging checks |
| Nix construction and routing | `support/nix.rs::Invocation` | Module visibility and execution delegation |
| Git and OpenSSH construction | Their domain modules | Module visibility and execution delegation |
| Run paths | One typed run-layout API | No path-segment construction elsewhere |
| Progress state | Event stream plus incremental reducer | Recovery and equivalence tests |
| Reports | Projection from persisted facts | Golden cross-surface tests |
| Diagnostics | Execution result and log-retention policy | Bounded failure fixtures |
| Artifact sizes | Artifact writers | Accounting-total tests |
| GitHub publication | One surface publisher | Permission and sanitizer types |
| Workflow coupling | Shared metadata or parsed structures | Structural workflow tests |
| Build helpers | Per-purpose helper derivations | Derivation-graph checks |

Before changing registry and update flows, review each entire subsystem and add
its repeated mechanisms to this ledger. Similar names alone do not prove that
two lifecycles share a rule; different implementations of the same contract do.

## Test structure

Tests move to their owning modules as each mechanism moves. Do not perform a
standalone mechanical split of the existing test file.

The remaining integration suite covers:

- request parsing through execution and exit;
- the three surfaces and their help;
- effect authorization;
- report and GitHub projections;
- durable-run recovery;
- capability realisation and prewarming; and
- workflow and derivation-graph boundaries.

Production failures become named end-to-end regressions. Golden tests remain
for rendered documents. Architecture tests prefer visibility, types, parsed
structures, and evaluated graphs over substring scans.

## Performance baseline

Record the following before changing packaging or execution:

- recursive closure bytes for the current package and unwrapped binary;
- cold and warm comment authorization and error-reply latency;
- substituted and locally built bytes for CLI startup;
- cold Rust build time;
- rebuild time after a Rust-only edit, fixture-only edit, and lock-file edit;
- preparation, task, and publication durations;
- event count and snapshot-fold time;
- artifact-accounting time; and
- successful, failed, and maximum run-log sizes.

Heavy builds and representative timing runs use the remote builder or CI. Each
performance phase reports before and after values from the same procedure.

## Migration order

### 1. Blocked outcomes

Add the persisted policy and distinct outcome, then cover direct execution,
reports, process status, and bisect in one vertical path.

Completion requires tests for one and many blocked jobs, mixed direct and
blocked failures, all three policies, default behavior, serialization, and
end-to-end bisect classification.

### 2. Grammar surfaces and effects

Build the one grammar, exhaustive surface metadata, help projection, and effect
derivation. Move terminal and comment entry points to it, then delete the
untrusted command tree and adapter-specific option reconstruction.

Completion requires identical shared syntax on all surfaces, graceful
cross-surface errors, `--plan` on comments, no inapplicable flags in help, and a
test that rejects every unclassified command-tree node.

### 3. Execution engine

Define the child-process contract, migrate every process start, and remove raw
execution helpers that bypass it. Preserve domain-specific Nix, Git, and
OpenSSH construction.

Completion requires one lifecycle record and one diagnostic policy for every
child, including cancellation and timeout tests.

### 4. Baseline and minimal package

Capture the performance baseline, export `wasinix-core`, and switch comment
authorization, help, and failure replies to it. Do not add on-demand
capabilities until the closure reduction is measured.

Completion requires those commands to work without the optional program
closure and a measured reduction in transferred bytes and response latency.

### 5. Capability resolver

Create separate locked helper outputs and route one large capability through
the typed resolver. Migrate the remaining candidates one at a time and remove
their runtime inputs from the default package.

Completion requires deterministic trusted installables, distinct realisation
errors, process memoisation, and closure tests proving capabilities remain
separate.

### 6. Prewarming

Derive anticipated capabilities from the parsed command and overlap one
bounded realisation with useful work. Measure used, unused, and hidden time
before expanding speculation.

Completion requires owned cancellation, no duplicate realisation, no
unexpected local build, and metrics sufficient to disable an unhelpful
prediction.

### 7. Preparation and state

Move all preparation steps into the event model, make snapshot reduction
incremental, and replace directory scans with writer accounting.

Completion requires observable current work during every long phase, recovery
equivalence between incremental and full folds, and no task-count multiplied
filesystem traversal.

### 8. Log bounds and run collection

Bound live transcripts, preserve bounded diagnostic evidence, publish it, and
add explicit run retention and collection.

Completion requires a stress test that cannot exceed the configured run
budget, correct truncation metadata, protected active and pinned runs, and
cleanup only after durable publication.

### 9. Helper translation

Classify each remaining shell or Python helper by build-graph role. Translate
host control-plane logic into the CLI, foundational logic into narrow helper
derivations, and leaf logic beside its consumer. Delete each old path when its
replacement lands.

Completion requires the foundational dependency check and source-hash tests
showing that unrelated CLI edits do not rebuild protected outputs.

### 10. Registry, update, and workflow convergence

Review each whole subsystem, extend the convergence ledger, and replace its
repeated credential, serving, publishing, reply, and workflow mechanisms by
rule. Preserve genuinely different lifecycles as different types.

Completion requires no known repeated contract outside its named owner and no
workflow coupling protected only by substring matching.

### 11. Rust build experiment

After source and closure boundaries stabilise, compare the current
`buildRustPackage` with Crane dependency artifacts. Measure cold builds,
Rust-only edits, fixture-only edits, lock-file edits, shared test artifacts, and
derivation complexity.

Adopt Crane only when it materially improves incremental builds without
obscuring the dependency graph or invalidation boundaries.

## Completion criteria

The plan is complete when:

- blocked work follows the requested policy without ever masquerading as
  green;
- terminal, comment, and CI commands parse through one grammar;
- every grammar node has a fail-closed surface classification;
- every side effect is derived and authorized after parsing;
- every child process uses the shared execution engine;
- optional tools are absent from the minimal closure and realised only through
  typed locked capabilities;
- preparation and capability work is observable as structured progress;
- snapshot and artifact telemetry scale with new events and artifacts rather
  than accumulated history;
- run storage remains within measured budgets during and after execution;
- foundational derivations cannot depend on the main CLI;
- every convergence-ledger row has one owner and structural enforcement;
- all failing targets are fixed or explicitly accepted by policy; and
- the complete test suite and the relevant freshly measured remote or CI
  checks pass.
