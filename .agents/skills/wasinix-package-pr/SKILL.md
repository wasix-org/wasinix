---
name: wasinix-package-pr
description:
  Package requested software for WASIX, create a draft pull request when
  explicitly requested, and iterate on the scoped branch until the matching CI
  run is green. Use for requests such as "package X, make a draft PR, and keep
  going until CI is green."
---

# Package and draft PR

Read `AGENTS.md`, `docs/style.md`, `docs/building.md`, `docs/packaging.md`, and
the relevant language and registry documentation before editing. Find the
closest sibling before choosing a package shape. State a new mechanism's design
and obtain agreement before implementing it.

Create, push, or open a draft PR only when the request explicitly authorizes
that action. Keep the PR draft until the request says otherwise.

After pushing, run `wasinix pr watch <pr>`. Treat `green` as the only success
result. For `failed`, read the CI report and archived logs, fix the root cause,
push the scoped branch, and watch the new run. For `stalled` or `incomplete`,
report the run and last observed state; do not retry, cancel, or claim green.

Finish with the PR URL, the final CI state, the checks run, and any blocker.
