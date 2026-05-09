# tests/

Nix-based integration tests that verify WASIX program behavior.

## Structure

- `lib.nix` — test primitives (`mkWasixRun`, `mkScriptComparison`, etc.)
- `default.nix` — collects all program test suites into a grouped attrset
- `programs/<name>/` — test suite per program; `helpers.nix` (if present) provides shared setup

## Test patterns

**`mkWasixRun`** — run a script under wasmer; pass if it exits 0.

**`mkScriptComparison`** — run a script both natively and under wasmer, diff the outputs; pass if identical. Accepts an optional `normalize` script for deterministic comparison.

## Running

```sh
# All tests
nix build .#tests.all

# Single program group
nix build .#tests.git.all

# Single test
nix build .#tests.git.workflow-compare
```

To test against a local wasmer binary:

```sh
WASMER_BIN=/path/to/wasmer nix build .#tests.all --impure
```
