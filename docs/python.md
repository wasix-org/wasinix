# Python

How CPython, extension modules, and wheels are built for WASIX. General package
authoring is covered by
[`packaging.md`](packaging.md#a-python-package-or-wheel).

## CPython and its package set

CPython needs dynamic linking for extension modules, so it is built only in the
`ehpic` profile. Its overlay lives in `pkgs/overlay/packages/python3/`.

Python package adaptations live in `pkgs/overlay/python-packages/`. They follow
the normal overlay conventions, with `pyfinal` and `pyprev` for dependencies in
the Python package set. Rust extension modules use the shared Rust wheel hooks
described in [`rust.md`](rust.md).

## Wheels

`pkgs/overlay/python-packages/wheels.nix` declares the shipped wheels.
`pkgs/python-wheels.nix` turns those declarations into build targets and runs
their import tests under Wasmer. The wheel index and publication flow are
described in [`registry.md`](registry.md#the-python-wheel-index).

For package selection and coverage, see
[`python-coverage.md`](python-coverage.md). The survey data behind that work is
in [`../pypi-survey/`](../pypi-survey/). Refresh it with
`wasinix python survey refresh`, not as part of the offline coverage report.
