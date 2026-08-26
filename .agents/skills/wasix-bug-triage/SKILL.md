---
name: wasix-bug-triage
description:
  Find and triage suspected WASIX bugs from patches, disabled tests, captured
  failures, or reports; reduce them to minimal evidence-backed reproducers
  without changing shipping code. Use when asked to investigate WASIX
  compatibility failures or existing workarounds.
---

# WASIX bug triage

Read `AGENTS.md`, `docs/style.md`, `docs/building.md`, `docs/spot.md`, and the
relevant package or language documentation. Search `WASIX-TODO.md` before
treating a workaround as a new bug.

Inventory patches, disabled tests, `broken` declarations, and observed failures.
Group structurally identical symptoms, identify the likely owner, and reduce
each candidate from a real failing package to the smallest reproducer that still
fails under Wasmer. Use Spot for inexpensive experiments, then distinguish its
evidence from final verification.

Do not edit shipping code, mark work broken, disable tests, open issues, or
contact upstream unless explicitly requested. Report each reproducer, the exact
failure, affected scope, existing tracking, likely owning layer, and the next
discriminating experiment.
