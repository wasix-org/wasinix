# Python

How CPython, extension modules, and wheels are built for WASIX. General package
authoring is covered by
[`packaging.md`](packaging.md#a-python-package-or-wheel).

## CPython and its package set

CPython needs dynamic linking for extension modules, so it supports the `ehpic`
and `exnrefEhpic` profiles and prefers `exnrefEhpic`. Its overlay lives in
`pkgs/wasix/python3/`; the `py313` and `py314` package fixpoints use that
preferred profile.

Python package adaptations live in `pkgs/python/`. They use the same package
unit API as other lanes: `packages.sameProfile` is the immediate Python
fixpoint, while `pkgs` is the enclosing WASIX set. Rust extension modules use
the shared Rust wheel hooks described in [`rust.md`](rust.md).

## Wheels

`pkgs/python/wheels/default.nix` declares the shipped wheels.
`pkgs/python-wheels.nix` turns those declarations into build targets and runs
their import tests under Wasmer. The wheel index and publication flow are
described in [`registry.md`](registry.md#the-python-wheel-index).

For package selection and coverage, see
[`python-coverage.md`](python-coverage.md). The survey data behind that work is
in [`../pypi-survey/`](../pypi-survey/). Refresh it with
`wasinix python survey refresh`, not as part of the offline coverage report.
