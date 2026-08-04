# Python coverage roadmap

How much of PyPI installs on wasix, what blocks the rest, and in what order to
fix it. Numbers come from the vendored `pypi-survey/` (top-10k PyPI packages by
30-day downloads, ranking snapshot 2026-07-01, surveyed 2026-07-16); see
`pypi-survey/README.md` for method and `pypi-survey/findings.md` for the full
tables, cross-referenced against the wheels this repo publishes.

## The model

Pure-python packages cost nothing per package:

- Cross builds skip the run-only phases, so a pure wheel builds through the
  nixpkgs cross stdenv untouched. A `python-packages/<attr>.nix` is only ever a
  build fix, never a prerequisite.
- The registry publishes every shipped wheel plus its transitive python deps
  (`packaging.md`), so shipping one app lands its whole pure closure.

Coverage is therefore gated entirely by native packages sitting in other
packages' closures. 85.4% of the top-10k is pure, but only 58.5% has a fully
pure closure. The gap is pure packages held hostage by one native dep, and that
gap is what a native build buys back.

## Where we are

A package counts as buildable when every native package in its dependency
closure is published. Against the current registry closure (215 wheels):

| cutoff     | buildable | blocked | out of scope |
| ---------- | --------- | ------- | ------------ |
| top 100    | 98.0%     | 2       | 0            |
| top 1,000  | 88.6%     | 110     | 32           |
| top 10,000 | 78.5%     | 2,084   | 304          |

Out-of-scope packages are excluded from the denominator; see below.

The shipped native set is the registry closure, not `wheels.nix`: transitively
pulled deps (pyyaml, fonttools, wrapt, websockets, brotli) publish without a
worklist entry. Per-package build details live in each
`overlay/packages/<pkg>.nix` / `overlay/python-packages/<pkg>.nix` and the
commit that added it.

## Recompute

Take the shipped set from

```
nix eval --json .#legacyPackages.x86_64-linux.pythonRegistry.wheels.py313 \
  --apply builtins.attrNames
```

and intersect it with the closures in `pypi-survey/data/transitive.json`.

## Burn-down

Greedy order, each build unblocking the most still-blocked packages:

| target            | builds needed |
| ----------------- | ------------- |
| top 1,000 to 90%  | 7             |
| top 1,000 to 95%  | 30            |
| top 1,000 to 99%  | 64            |
| top 10,000 to 90% | 38            |
| top 10,000 to 95% | 100           |
| top 10,000 to 99% | 183           |

`scipy` dominates the head: 344 top-10k packages (3.5 points) hang off it alone,
more than the next six combined.

## Out of scope

Declared, not attempted. Roughly 3% of the top-10k.

- GPU and CUDA: `torch`, `triton`, `nvidia-*`, `cuda-*`, `jaxlib`,
  `torchvision`, `torchaudio`, `onnxruntime` (GPU), `tensorflow`, `vllm`,
  `sglang`, `flash-attn`, `xformers`, `deepspeed`. No GPU under wasmer, and
  these publish binary-only wheels regardless.
- macOS frameworks: all `pyobjc-*`. Never pulled on a wasix target anyway;
  they appear in the survey only because it evaluates markers for linux.
- Runtime JIT: `llvmlite` and `numba` (49 and 47) need an LLVM JIT at runtime.
- `libclang` (22), `playwright` (17): bundled toolchain or browser payloads.

## Demand side

Unblocking a native package does not by itself publish the packages it
unblocks. They reach the registry only as the closure of something in
`wheels.nix`. Two ways to close that gap:

- Curated apps, the current model: add top-level packages, deps ride along.
  Good signal per entry, uneven coverage.
- Survey-driven worklist: generate `wheels.nix` pure entries for every top-N
  package whose native closure is already satisfied. Pure builds are cheap, so
  this is what turns the coverage percentage into an actually populated
  registry. Gate by cutoff (top-1k first) to bound CI cost.

Either way, re-run the burn-down after each native build lands: the newly
unblocked set is the next batch of pure entries.
