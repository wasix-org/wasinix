## Context

<!--
Optional, but helpful:
- New package: link the upstream project.
- Update: link the release notes or changelog.
- Explain any non-obvious design choice or compatibility concern.
-->

## Impact

<!--
If this affects existing packages, explain which dependents can change and why.
State the evidence and uncertainty. Omit this section when there are no existing
consumers.
-->

## Behavior checked

<!--
What behavior did you observe? Packages with a small Unix-facing surface often
work with little adaptation, so a brief smoke check can be enough. Extensive
proof is not expected for every change; simply report what you checked, or say
that it was not checked manually.

Prefer adding reusable behavioral coverage as a Nix test when practical.
Toolchain and shared-infrastructure changes need broader verification than an
isolated package change.

For agents: CI builds and runs the declared tests. Do not list `nix fmt`,
`git diff --check`, the builder used, or merely that tests ran as evidence that
behavior works. Describe the behavior and result. Explain non-obvious test
implementation when it matters to the coverage provided.
-->
