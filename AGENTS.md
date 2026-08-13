# Working in this repo as an agent

`AGENTS.md` contains only guidance specific to agents and not owned by one
topic. Put guidance that applies to humans and agents in the relevant general
doc:

| Read                   | For                                                 |
| ---------------------- | --------------------------------------------------- |
| `CONTRIBUTING.md`      | contribution and PR expectations                    |
| `docs/architecture.md` | how the layers fit together and flake outputs       |
| `docs/c.md`            | C/C++ toolchain, profiles, and cross stdenv         |
| `docs/packaging.md`    | adding a package, tweaks, deps, patches, tests      |
| `docs/registry.md`     | publishing, version history, rels, PR previews      |
| `docs/rust.md`         | rust builds, crate patches, the cargo registry      |
| `docs/python.md`       | CPython, package overlays, and wheels               |
| `docs/building.md`     | where builds run, building one thing, checking work |
| `docs/style.md`        | comments, naming, commits, fail loud, root cause    |
| `docs/updating.md`     | the pin updater and `updateNotes`                   |
| `docs/spot.md`         | experimenting without rebuilding the world          |

Do not restate those rules here. Add a `## For agents` section to the owning doc
only when the agent workflow genuinely differs from the human workflow.

## Before you write code

Every new file, test, package, patch, or script has a sibling here that already
does the same kind of thing. Find it and match its location, naming, and
structure. If you cannot find one, say so before inventing a layout.

Before implementing a new mechanism, state the design in one or two sentences
and get agreement. Prioritise a single source of truth and the smallest diff
that slots into existing machinery. Work already done is not an argument for
keeping a shape: if the design is wrong, say so rather than defending it.

## The three that get violated most

These are in the docs, and are repeated here only because they are the ones most
often missed:

- **Comments.** The seven checks in `docs/style.md` are pass/fail, not matters
  of taste. Verbose, changelog-style, context-assuming comments are the single
  most repeated complaint about AI-authored code in this repo. Re-read them
  against your final diff, not against your intent while writing.
- **Never build locally.** `docs/building.md`. Heavy builds go to the remote
  builder. `--builders ""` means "build on the user's desktop" and will thrash
  it into swap. A wide nix-eval-jobs fan-out does the same through RAM, so cap
  its workers. Read a failing log rather than rebuilding to see the error.
- **Fix the root cause.** `docs/style.md`. Excluding, skipping, or marking
  broken to go green is the user's call, never yours, and they can only make it
  once you have said what it costs.

## Working with the user

- A question is a request for an answer. Do not edit code in response to "why is
  this like that".
- Once a task is authorized, run it to completion. Stop only for a real blocker:
  a failed prerequisite, a genuine ambiguity, or a decision that is the user's
  to make. Do not stop with a next step already in hand.
- Read a file immediately before overwriting it. The user hand-edits files
  between your turns, and a stale copy in context will clobber their work.
- Never revert, discard, or undo a change unless asked.
- Addressing review feedback means reading the whole source, not a grep or a
  summary, and resolving each comment individually.
- Do not state a tool or build-system behaviour as fact without checking it. If
  it is unverified, say so.
- Do not attribute intent to existing code ("deliberately", "intentionally")
  without a comment or commit backing it. If the reason is unknown, say that.
- Use the user's exact term for a concept. `xfail` is not `broken`; `cc-wrapper`
  (nixpkgs) is not `wasixcc` (wasix-org).
- Sub-agents and worktrees must be synced to current HEAD before dispatch.

## Never act in the user's name

No `git push`. No opening or closing PRs or issues. No GitHub comments of any
kind, including replies to review threads. No commits unless asked.

Writing the code is not authorization to ship it. "Fix this" and "go ahead"
authorize the edit, never the commit or the push, and approval for one push is
not approval for the next. Do not offer a push or a PR as the next step. When
public text is needed, draft it in chat or hand over the `gh` command.

## Cleaning commit history

Rewrite history only when the user asks. Review the whole PR range from its
target-branch merge base, and check whether it is published. Never rewrite
user-authored commits or work outside the requested range; published history
needs explicit authorization.

Make the range tell one dependency-ordered story. Each commit should introduce
one reviewer-visible idea, fold in its later corrections, and leave an
internally consistent tree that is useful to bisect. Preserve authorship and the
final tree exactly, then verify both against the pre-rewrite range. Do not push
it.

## Before you report done

- Comments re-read against the seven checks in `docs/style.md`, in the final
  diff.
- Every failing target fixed, or excluded with the user's agreement on record.
- The claim you are about to make actually run, just now. No "should work".
- Nothing built at scale on the user's machine.
- Nothing pushed, posted, or committed unless asked for in this message.
