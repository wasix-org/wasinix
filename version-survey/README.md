# PyPI historical-version survey

**Survey window: 2026-07-11 to 2026-08-09.** Which non-latest versions of the
top 1,000 PyPI projects are actually being installed, which projects keep the
semver promise, and which historical versions are therefore worth building
rather than resolving to something newer.

Motivation: sizing a multi-version WASIX Python package registry for wasinix.
Companion to the top-10k native-dependency survey in `../pypi-survey/`.

## Headline results

|                                                                    |                            |
| ------------------------------------------------------------------ | -------------------------- |
| installs that were not the newest release available that day       | **41.3%**                  |
| installs that are not the latest release as of the window end      | 51.0%                      |
| installs inside the major line that was current that day           | 89.0%                      |
| median age of the release actually installed                       | 258 days                   |
| top 5 versions per project cover                                   | 80.3% of installs          |
| dependency requirements in the wild that forbid the current latest | 14.1%                      |
| historical traffic the current release could serve instead         | 57.1%                      |
| (project, version) pairs that actually need their own build        | 755 (571 pure, 184 native) |

Full numbers, per-project tables and the build/alias recommendation lists:
**[findings.md](findings.md)**.

The reproduce pipeline also emits `report.html`, the same survey as a
self-contained page with charts. It and the aggregates it embeds
(`data/page_data.json`) are generated, not vendored in this copy; regenerate
them with the reproduce steps.

## Files

| file                             | contents                                                                                                             |
| -------------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| `findings.md`                    | every table: concentration, live major lines, scheme breakdown, measured breakage, ecosystem caps, build/alias lists |
| `data/top.json`                  | the ranking snapshot (ClickHouse `pypi` dataset, resolver traffic only)                                              |
| `data/downloads_by_version.json` | per-(project, version) 30-day download counts                                                                        |
| `data/releases.json`             | per-project release list with upload time and `requires_python`                                                      |
| `data/usage.json`                | per-project version concentration, major-line split, installed-release age                                           |
| `data/requirements.json`         | every dependency requirement string in the ecosystem targeting a surveyed project                                    |
| `data/caps.json`                 | per-project: how often dependents cap it, and where the cappers land                                                 |
| `data/scheme.json`               | version scheme classification and major-bump cadence                                                                 |
| `data/api_jobs.json`             | wheels the API diff introspects, as `[project, version, url]`                                                        |
| `data/api_targets.json`          | per-project: latest plus the versions the diff covers                                                                |
| `data/api_diff.json`             | public-API diff of each in-use version against its project's latest                                                  |
| `data/recommend.json`            | per-(project, version) substitution verdict, ranked by install volume                                                |
| `data/python_split.json`         | modern (>=3.12) vs legacy interpreter split per version                                                              |
| `data/timely.json`               | each install scored against the release that was newest on that day                                                  |
| `data/history_jobs.json`         | wheels the registry selection introspects, same shape as `api_jobs.json`                                             |
| `data/history_picks.json`        | per wheel attr: the older versions to keep building, and why each earns a build                                      |
| `scripts/`                       | everything needed to reproduce, in run order                                                                         |

## Reproducing

Needs python3 (stdlib + `packaging`) and network access. ~25 min, ~1 GB of wheel
traffic that is streamed and discarded rather than stored.

```
python3 scripts/fetch_downloads.py 1000    # ClickHouse -> top.json, downloads_by_version.json, releases.json
python3 scripts/fetch_index.py             # PyPI simple index -> cache/ (per-version upload time, yank, wheel tags)
python3 scripts/analyze_usage.py           # -> usage.json
python3 scripts/fetch_python.py            # interpreter split -> python_split.json
python3 scripts/fetch_caps.py              # ecosystem requirement strings -> requirements.json
python3 scripts/analyze_caps.py            # -> caps.json
python3 scripts/analyze_scheme.py          # -> scheme.json
python3 scripts/analyze_timely.py          # newest-on-the-day scoring -> timely.json
python3 scripts/build_jobs.py 600          # choose which wheels to introspect -> api_jobs.json
python3 scripts/api_extract.py data/api_jobs.json   # AST-parse wheels -> cache/api/
python3 scripts/api_diff.py                # -> api_diff.json
python3 scripts/recommend.py               # -> recommend.json
python3 scripts/prep_report.py             # -> page_data.json
python3 scripts/gen_findings.py            # -> findings.md
python3 scripts/gen_page.py                # -> report.html
```

## Choosing which versions wasinix builds

The survey verdicts diff each in-use version against PyPI's latest. A registry
cares about the version it actually ships, so `select_history.py` re-diffs the
candidates against that, then keeps the head of every major line with real
traffic plus any version enough published projects resolve to exactly.

It takes a JSON object mapping wheel attr to the version the tree ships,
`{"numpy": "2.5.1", ...}`:

```
python3 scripts/select_history.py jobs wheel-versions.json  # -> history_jobs.json
python3 scripts/api_extract.py data/history_jobs.json       # AST-parse wheels -> cache/api/
python3 scripts/select_history.py pick wheel-versions.json  # -> history_picks.json
```

Each pick becomes a `scripts/history.py add <attr>==<version>` in the repo root,
which is what writes the history tables the registry builds from.

## Method notes & caveats

- **Download data** is ClickHouse's public `pypi` dataset. Counts are restricted
  to real resolvers (`pip`, `uv`, `poetry`, `pdm`, `pex`, `Bazel`), which drops
  bandersnatch mirror traffic, which fetches every version equally and would
  wildly inflate the historical tail. As always, PyPI download counts are
  dominated by CI, so "in use" means "something automated installs it
  repeatedly", not "a human chose it".
- **The public ClickHouse endpoint silently truncates.** Its default profile
  sets `max_rows_to_read=1e10` with `read_overflow_mode=break`, so large scans
  return partial, run-to-run inconsistent results with no error. `scripts/ch.py`
  lifts that; without it the same single-day sum varies by 15% between runs. A
  second, separate cap truncates any result past a few hundred thousand rows,
  also non-deterministically, so the per-day query pages through an explicit
  `ORDER BY`.
- **Latest version** is the highest non-prerelease, non-fully-yanked release in
  the PyPI simple index as of the window end.
- **API diff** AST-parses both wheels and compares exported names. It counts
  module-level functions, classes, public methods and attributes, constants,
  `__all__` entries, and relative re-exports; it deliberately ignores absolute
  imports (`from typing import Tuple` is machinery, not API) and anything under
  a `_`-prefixed module path. A removal is therefore evidence that the newer
  release cannot silently stand in for the older one. Dynamic `__getattr__`
  re-exports and module renames still produce false positives, so the breakage
  rate is an upper bound; `removed_root` (names gone from the top-level package
  namespace) is the high-precision signal and drives the verdicts.
- **Coverage**: the diff covers the top 600 projects and, within each, the
  versions holding at least 2% of that project's traffic, up to 6 per project
  plus the latest. Pairs outside that set appear in `recommend.json` as
  `unmeasured`. Wheels over 40 MB (pyarrow, torch) are skipped.
- **Dependency constraints** come from the latest release of every PyPI project
  published since 2024. Environment markers and extras are stripped before
  parsing, so a requirement that only applies on Windows still counts.
- Two known gaps in ClickHouse's `pypi.projects` mirror: it is missing some
  popular projects entirely (`langchain`, `fsspec`, `playwright`,
  `opencv-python`, `kubernetes`), which is why release metadata comes from
  PyPI's simple index instead. It is used only for the ecosystem-wide
  requirement scan, where those absences are noise.
