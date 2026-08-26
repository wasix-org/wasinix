---
name: wasinix-update-babysit
description:
  Babysit explicitly scoped Wasinix update pull requests by diagnosing CI
  failures, applying root-cause fixes, and pushing only when requested until
  their matching CI run is green. Use for requests to repair update PRs or keep
  update branches green.
---

# Update PR babysit

Read `AGENTS.md`, `docs/style.md`, `docs/building.md`, `docs/ci.md`,
`docs/updating.md`, and the relevant package documentation. Work only on the
named update PRs and preserve the managed-update rules in `docs/updating.md`.

Run `wasinix pr watch <pr>` after each authorized push. For a failed run, read
the CI report and logs before changing code, fix the root cause without dropping
coverage, then push only if the request authorized it. A `stalled` or
`incomplete` result is a handoff with the last state, not permission to retry or
cancel.

Finish only when every scoped PR is green, or report the exact remaining blocker
and evidence.
