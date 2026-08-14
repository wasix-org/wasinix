# PyPI top-10k native-dependency survey

**Survey date: 2026-07-16.** How many of the top 100 / 1,000 / 10,000 PyPI
packages (by 30-day downloads) are pure Python vs ship native code, what the
native ones are built from, and how native packages get pulled into dependency
closures.

Motivation: sizing the native-code problem for WASIX Python packaging (wasinix).
Companion to the historical-version survey in `../version-survey/`, which asks
which non-latest versions of these packages are actually installed.

## Headline results

|            | pure  | native (self) | needs native anywhere in dep closure |
| ---------- | ----- | ------------- | ------------------------------------ |
| top 100    | 75%   | 25%           | 40%                                  |
| top 1,000  | 79.2% | 20.8%         | 53.5%                                |
| top 10,000 | 85.4% | 14.6%         | ~58.5%                               |

Full numbers, per-cutoff breakdowns (languages, build backends, ABI kinds,
bundled shared libraries) and the reach ranking: **[findings.md](findings.md)**.

The reproduce pipeline also emits `flame.html`, an interactive
reverse-dependency chart: roots are native packages sized by how much they're
pulled, the levels below answer "via which dependent", and it toggles between
package-count and download weighting. The flame outputs (`flame.html`,
`data/flame_full.json`, `data/flame_view.json`, `data/page_data.json`) are
generated, not vendored in this copy; regenerate them with the reproduce steps.

## Files

| file                        | contents                                                                                       |
| --------------------------- | ---------------------------------------------------------------------------------------------- |
| `findings.md`               | all tables: classifications, transitive closure, breakdowns, top-100 native list, reach top-50 |
| `flame.html`                | self-contained interactive flame chart + tables (generated; not vendored)                      |
| `data/top.json`             | the ranking snapshot (hugovk/top-pypi-packages, 2026-07-01)                                    |
| `data/classified.json`      | per-package verdict: pure / native (+ final after sdist refinement)                            |
| `data/transitive.json`      | per-package closure verdict + direct native deps                                               |
| `data/wheel_inspect.json`   | per-native-package: wheel generator, abi, extension count, bundled libs                        |
| `data/sdist_scan_*.json`    | sdist source-file / build-system scans                                                         |
| `data/sdist_refined.json`   | native-or-pure verdicts for sdist-only packages (incl. hand overrides)                         |
| `data/native_optional.json` | native packages that also ship a pure `py3-none-any` fallback wheel                            |
| `data/reach.json`           | per-native-package: how many top-10k packages pull it (+ download-weighted)                    |
| `data/flame_full.json`      | unpruned flame tree, `c` = packages, `d` = downloads (generated; not vendored)                 |
| `data/flame_view.json`      | pruned tree embedded in flame.html (generated; not vendored)                                   |
| `data/page_data.json`       | aggregates embedded in flame.html (generated; not vendored)                                    |
| `scripts/`                  | everything needed to reproduce, in run order (see below)                                       |

## Reproducing

Needs python3 (stdlib + `packaging`), ~55 MB of PyPI JSON metadata cache, ~15
min:

```
python3 scripts/fetch_meta.py 10000        # PyPI JSON metadata -> cache/
python3 scripts/classify.py 10000          # wheel-tag classification -> classified.json
python3 scripts/sdist_scan.py sdist_only 10000
python3 scripts/refine_sdist.py            # sdist-only refinement (edit overrides inside)
python3 scripts/wheel_inspect.py 10000     # ranged-HTTP wheel inspection (no full downloads)
python3 scripts/transitive.py              # dep-closure analysis
python3 scripts/sdist_scan.py native 10000 # language attribution scans
python3 scripts/build_flame.py OUT         # flame tree + reach
python3 scripts/prep_report.py OUT         # findings.md + page_data.json
python3 scripts/gen_page.py OUT            # flame.html from template.html
```

## Method notes & caveats

- **Native** = latest release publishes a platform-specific wheel, or its sdist
  builds compiled code (`ext_modules` / Cython / Cargo / CMake / meson signals).
  Packages whose compiled part is optional but which ship a pure fallback wheel
  still count as native (tracked separately in `native_optional.json`).
  `pyspark` counts as pure (JARs, not CPython extensions). Two junk packages
  (`aaaaaaaaa`, `timedelta`) excluded.
- **Closure**: `requires_dist` of latest releases, markers evaluated for CPython
  3.12 / linux / x86_64, no extras. Extras and version-range back-solving are
  not modeled, so transitive numbers slightly undercount.
- **Flame attribution**: each (package, native dep) pair contributes once, along
  the package's shortest dependency path, so a package reaching numpy both
  directly and via pandas is counted on the direct edge only. Most pulls of big
  libraries are direct, which is why "(other)" (folded one-off dependents)
  dominates under the roots.
- **Language** is a single primary label per package (source-file majority +
  toolchain signals). Vendored sources are the main hazard (numpy vendors `.rs`
  files; Eigen vendors Fortran LAPACK), so Rust requires a toolchain signal, not
  just sources. ~29% of native packages publish no sdist (binary-only: torch,
  CUDA wheels, repackaged CLIs) and stay unattributed.
- Downloads are the ranking snapshot's 30-day counts; mirrors/CI dominate PyPI
  download stats, as always.
