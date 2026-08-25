# Python

How CPython, extension modules, and wheels are built for WASIX. General package
authoring is covered by
[`packaging.md`](packaging.md#a-python-package-or-wheel).

## CPython and its package set

CPython needs dynamic linking for extension modules, so it supports the `ehpic`
and `exnrefEhpic` profiles and prefers `exnrefEhpic`. Its overlay lives in
`pkgs/overlays/p/python3/`; the `py313` and `py314` package fixpoints use that
preferred profile.

Python package adaptations live in one-character buckets under
`pkgs/python-overlays/`. They use the same package unit API as the regular
inventory: `packages.sameProfile` and `packageSet` are the immediate Python
fixpoint, while `pkgs` is the enclosing WASIX set. Rust extension modules use
the shared Rust wheel hooks described in [`rust.md`](rust.md).

## Wheels

`pkgs/python/wheels/default.nix` declares the shipped wheels.
`pkgs/python/wheels/project.nix` turns those declarations into build targets and
runs their import tests under Wasmer. The wheel index and publication flow are
described in [`registry.md`](registry.md#the-python-wheel-index).

Focused wheel behavior tests live in
`pkgs/python-overlays/<first-character>/<attr>/tests/*.nix` and use
`harnesses.python`. The harness installs the wheel and explicit test
dependencies into a clean target, then runs it through the packaged Python WebC
without a Nix store mount.

Each Python variant declares the WASIX interpreter package it uses, and exactly
one variant is preferred. Architecture-independent wheels are built once with
that preferred variant. The combined registry is a project artifact derived from
every cataloged wheel; changing the preferred variant changes its Python runtime
and the owner of architecture-independent wheels without changing the aggregate
mechanism.

For package selection and coverage, see
[`python-coverage.md`](python-coverage.md). The survey data behind that work is
in [`../pypi-survey/`](../pypi-survey/). Refresh it with
`wasinix python survey refresh`, not as part of the offline coverage report.
