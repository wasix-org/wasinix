---
name: wasix-root-cause-experiment
description:
  Experiment with root-cause fixes for specifically scoped, triaged WASIX bugs
  and report reproducible before-and-after evidence. Use when asked to test a
  proper fix for a known WASIX failure.
---

# WASIX root-cause experiment

Read `AGENTS.md`, `docs/style.md`, `docs/building.md`, `docs/spot.md`, and the
documentation for the owning layer. Start from the triaged reproducer, not a
broad package sweep.

State the proposed root fix and the narrow test matrix before changing code.
Test the reproducer before and after the change, then use the appropriate full
verification before proposing a shipping fix. Search for structurally identical
consumers and cover them through the shared implementation.

Keep this as an experiment unless the request explicitly authorizes a PR, push,
or landing change. Report the hypothesis, patch location, before-and-after
evidence, remaining uncertainty, and the next safe step.
