# PyPI historical-version survey

**Survey window: 2026-07-11 to 2026-08-09** (30 days), top 1000 PyPI projects by
installer traffic, 159.2B downloads.

Three questions, for sizing a WASIX Python package registry that would carry
more than one version per package:

- **(a)** which non-latest versions are actually being installed;
- **(b)** which projects keep the semver promise, so a newer release can stand
  in for an older one;
- **(c)** which historical versions are worth building, and which can just
  resolve to something newer.

## Headline

|                                                                  |                                              |
| ---------------------------------------------------------------- | -------------------------------------------- |
| installs that were **not** the newest release available that day | **41.3%**                                    |
| installs that are not the latest release as of the survey end    | 51.0%                                        |
| installs within the **major** line that was current that day     | 89.0%                                        |
| installs within the latest **minor** line                        | 57.1%                                        |
| of the non-latest half, still inside the current major           | 75.8%                                        |
| of the non-latest half, on an older major                        | 24.2%                                        |
| median age of the release actually installed                     | 258 days                                     |
| dependency requirements in the wild carrying an upper bound      | 23.5%                                        |
| dependency requirements that forbid the current latest           | 14.1% (5.7% by range cap, 8.4% by exact pin) |

Two numbers, because the naive one is unfair to fast-moving projects: measured
against a fixed "latest" at the end of the window, 51.0% of installs are
historical; measured against whatever was newest on the day of each install,
41.3% are. Either way roughly nine tenths of traffic stays inside the current
major line, so the version tail is mostly **lag** rather than
**incompatibility**, and lag is the cheap case.

## (a) Which non-latest versions are in use

### Lag, measured fairly

A 30-day window against a fixed "latest" punishes projects that release daily:
boto3 ships a new version most weekdays, so its current release owns one day of
the window and scores 0.4%. Recomputing each install against the release that
was newest on the day it happened, over 159.2B downloads, gives **58.7% on the
newest release** and 89.0% inside the then-current major line. The rest of this
section uses the fixed-latest view, which is the one that matters for deciding
what a registry has to hold today.

### Concentration

| versions packaged per project | share of installs served |
| ----------------------------- | ------------------------ |
| top 1                         | 56.5%                    |
| top 2                         | 68.3%                    |
| top 3                         | 74.1%                    |
| top 5                         | 80.3%                    |
| top 8                         | 85.1%                    |
| top 12                        | 88.5%                    |
| top 20                        | 92.1%                    |
| top 25                        | 93.4%                    |

Distinct versions needed to cover 90% of one project's installs: median 4, p75
12, p90 27.

Per-project share of installs on the latest release, unweighted: p10 2.4%, p25
10.0%, median 53.2%, p75 82.1%, p90 97.2%. The median project sees about half
its installs on its newest release; a quarter of projects see under 10%.

### How old is the historical traffic

Non-latest versions holding at least 2% of their project's traffic, bucketed by
the age of the release being installed:

| age of the installed release | share of that traffic |
| ---------------------------- | --------------------- |
| under 6 months               | 47.0%                 |
| 6 months to 2 years          | 36.3%                 |
| over 2 years                 | 16.6%                 |

Installs on the latest release come from Python >=3.12 58.5% of the time;
installs of older releases 55.3% of the time. Old-version demand is not mostly
an old-interpreter artefact.

### Projects with a genuinely live older major line

83 projects (of 1000) send at least 10% of their installs to a major other than
the current one, on at least 100M installs. These are the real multi-version
packages:

| project              | latest       | off-current-major | build  | traffic by major                           |
| -------------------- | ------------ | ----------------- | ------ | ------------------------------------------ |
| `packaging`          | 26.3         | 11.2%             | pure   | 26: 89%, 25: 5%, 24: 5%, 23: 1%            |
| `urllib3`            | 2.7.0        | 15.7%             | pure   | 2: 84%, 1: 16%                             |
| `setuptools`         | 84.0.0       | 97.6%             | pure   | 83: 73%, 82: 8%, 80: 5%, 75: 2%            |
| `cryptography`       | 50.0.0       | 83.3%             | native | 49: 40%, 46: 18%, 50: 17%, 48: 9%          |
| `cffi`               | 2.1.1        | 10.6%             | native | 2: 89%, 1: 11%, 0: 0%                      |
| `numpy`              | 2.5.2        | 26.4%             | native | 2: 74%, 1: 26%                             |
| `aiobotocore`        | 3.9.0        | 86.6%             | pure   | 2: 68%, 1: 18%, 3: 13%, 0: 1%              |
| `pycparser`          | 3.0          | 18.0%             | pure   | 3: 82%, 2: 18%                             |
| `pytest`             | 9.1.1        | 48.6%             | pure   | 9: 51%, 8: 43%, 7: 5%, 6: 1%               |
| `attrs`              | 26.1.0       | 20.4%             | pure   | 26: 80%, 25: 12%, 24: 3%, 23: 2%           |
| `fsspec`             | 2026.7.0     | 62.6%             | pure   | 2026: 37%, 2025: 16%, 2023: 16%, 2021: 11% |
| `protobuf`           | 7.35.1       | 67.7%             | native | 6: 39%, 7: 32%, 5: 14%, 4: 10%             |
| `pandas`             | 3.0.5        | 62.8%             | native | 2: 51%, 3: 37%, 1: 12%, 0: 0%              |
| `s3fs`               | 2026.7.0     | 90.3%             | pure   | 2021: 18%, 2025: 17%, 2022: 17%, 2023: 15% |
| `pip`                | 26.2.1       | 12.9%             | pure   | 26: 87%, 25: 4%, 24: 4%, 9: 2%             |
| `starlette`          | 1.6.0        | 24.9%             | pure   | 1: 75%, 0: 25%                             |
| `rpds-py`            | 2026.6.3     | 35.7%             | native | 2026: 64%, 0: 36%                          |
| `rich`               | 15.0.0       | 34.9%             | pure   | 15: 65%, 14: 24%, 13: 11%, 12: 0%          |
| `websockets`         | 17.0.1       | 86.4%             | native | 16: 53%, 15: 29%, 17: 14%, 14: 1%          |
| `pytz`               | 2026.3.post1 | 26.9%             | pure   | 2026: 73%, 2025: 14%, 2024: 6%, 2023: 3%   |
| `importlib-metadata` | 9.0.0        | 80.0%             | pure   | 8: 63%, 9: 20%, 6: 8%, 7: 4%               |
| `virtualenv`         | 21.7.3       | 39.6%             | pure   | 21: 60%, 20: 39%, 16: 0%, 15: 0%           |
| `pillow`             | 12.3.0       | 19.7%             | native | 12: 80%, 11: 11%, 10: 5%, 8: 2%            |
| `zipp`               | 4.1.0        | 50.1%             | pure   | 4: 50%, 3: 50%, 1: 0%, 0: 0%               |
| `textual`            | 8.2.8        | 66.5%             | pure   | 8: 33%, 6: 24%, 7: 14%, 0: 9%              |
| `tzdata`             | 2026.3       | 18.9%             | pure   | 2026: 81%, 2025: 15%, 2024: 2%, 2023: 1%   |
| `wrapt`              | 2.3.0        | 44.1%             | native | 2: 56%, 1: 44%                             |
| `huggingface-hub`    | 1.27.0       | 16.3%             | pure   | 1: 84%, 0: 16%                             |
| `regex`              | 2026.7.19    | 11.4%             | native | 2026: 89%, 2024: 5%, 2025: 4%, 2023: 1%    |
| `pyarrow`            | 25.0.0       | 60.5%             | native | 25: 39%, 24: 10%, 21: 8%, 23: 7%           |

## (b) Who keeps the semver promise

### Declared scheme

| scheme        | projects | share of traffic | on latest | within latest major | dependents capping it | caps that exclude latest |
| ------------- | -------- | ---------------- | --------- | ------------------- | --------------------- | ------------------------ |
| semver-shaped | 681      | 68.9%            | 46.0%     | 85.4%               | 23.0%                 | 5.8%                     |
| zerover       | 228      | 17.3%            | 61.2%     | 100.0%              | 24.1%                 | 5.9%                     |
| two-component | 49       | 7.9%             | 56.8%     | 89.0%               | 24.9%                 | 3.9%                     |
| calver        | 19       | 4.4%             | 46.8%     | 69.9%               | 34.4%                 | 8.8%                     |

Major bumps per year: median 0.15, p75 0.35, p90 0.77. 101 of 681 semver-shaped
projects have never bumped a major at all, so for those "no major bump" cannot
mean "no breaking change".

### Measured breakage: public API removed between the installed version and the latest

Every in-use version above 2% share was diffed against its project's current
latest by AST-parsing both wheels and comparing the exported names. A removal
means the newer release cannot silently stand in for the older one.

| boundary crossed | diffs | any API removed or narrowed | root namespace broken |
| ---------------- | ----- | --------------------------- | --------------------- |
| patch            | 339   | 23.3%                       | 0.3%                  |
| minor            | 1335  | 40.4%                       | 3.6%                  |
| major            | 433   | 81.3%                       | 24.9%                 |
| same             | 10    | 0.0%                        | 0.0%                  |

The gradient is real: a major bump removes a root-namespace name 24.9% of the
time, a minor bump 3.6%, a patch bump 0.3%. So the major number does carry
signal, but a minor bump breaking the top-level namespace one time in 28 is too
often to treat "same major" as a substitution guarantee on its own.

### Worst non-major breakage seen (minor or patch boundary, names dropped from the root namespace)

| project                | latest  | diffs at minor/patch | with root removals | worst | names dropped                                                                                       |
| ---------------------- | ------- | -------------------- | ------------------ | ----- | --------------------------------------------------------------------------------------------------- |
| `duckdb`               | 1.5.5   | 6                    | 2                  | 170   | `ANALYZE`, `BinaryValue`, `BinderException`, `BitValue`                                             |
| `pymongo`              | 4.17.0  | 5                    | 1                  | 23    | `GridFS.__init__`, `GridFS.delete`, `GridFS.exists`, `GridFS.find`                                  |
| `tree-sitter`          | 0.26.0  | 3                    | 1                  | 16    | `Language.__init__`, `Language.build_library`, `Language.field_count`, `Language.field_id_for_name` |
| `fastmcp`              | 3.4.6   | 2                    | 2                  | 6     | `Client`, `Context`, `FastMCP`, `FastMCPApp`                                                        |
| `click-repl`           | 0.3.0   | 1                    | 1                  | 6     | `ClickCompleter.__init__`, `ClickCompleter.get_completions`, `PY2`, `bootstrap_prompt`              |
| `scikit-learn`         | 1.9.0   | 6                    | 5                  | 5     | `clone`, `config_context`, `get_config`, `set_config`                                               |
| `click`                | 8.4.2   | 6                    | 2                  | 4     | `BaseCommand`, `HelpOption`, `MultiCommand`, `OptionParser`                                         |
| `scipy`                | 1.18.0  | 6                    | 1                  | 4     | `ifft`, `linalg`, `rand`, `randn`                                                                   |
| `requests`             | 2.34.2  | 6                    | 6                  | 3     | `FileModeWarning`, `RequestsDependencyWarning`, `check_compatibility`                               |
| `matplotlib`           | 3.11.1  | 6                    | 1                  | 3     | `cbook`, `checkdep_usetex`, `rcsetup`                                                               |
| `itsdangerous`         | 2.2.0   | 2                    | 1                  | 3     | `JSONWebSignatureSerializer`, `TimedJSONWebSignatureSerializer`, `json`                             |
| `numba`                | 0.66.0  | 6                    | 6                  | 3     | `get_versions`, `test`, `version_info`                                                              |
| `polars`               | 1.43.2  | 6                    | 1                  | 3     | `PartitionByKey`, `PartitionMaxSize`, `PartitionParted`                                             |
| `botocore`             | 1.43.67 | 6                    | 3                  | 2     | `NullHandler`, `NullHandler.emit`                                                                   |
| `s3transfer`           | 0.19.2  | 6                    | 3                  | 2     | `NullHandler`, `NullHandler.emit`                                                                   |
| `uvloop`               | 0.22.1  | 1                    | 1                  | 2     | `EventLoopPolicy`, `install`                                                                        |
| `blinker`              | 1.9.0   | 2                    | 1                  | 2     | `WeakNamespace`, `receiver_connected`                                                               |
| `mpmath`               | 1.4.1   | 1                    | 1                  | 2     | `doctests`, `runtests`                                                                              |
| `llama-cloud-services` | 0.6.94  | 1                    | 1                  | 2     | `LlamaReport`, `ReportClient`                                                                       |
| `pytest`               | 9.1.1   | 2                    | 2                  | 1     | `PytestRemovedIn9Warning`                                                                           |
| `pydantic-core`        | 2.48.0  | 5                    | 2                  | 1     | `validate_core_schema`                                                                              |
| `beautifulsoup4`       | 4.15.0  | 3                    | 1                  | 1     | `BeautifulSoup.NO_PARSER_SPECIFIED_WARNING`                                                         |
| `websocket-client`     | 1.9.0   | 1                    | 1                  | 1     | `setReconnect`                                                                                      |
| `pytokens`             | 0.4.1   | 1                    | 1                  | 1     | `FStringState.State`                                                                                |
| `toolz`                | 1.1.0   | 1                    | 1                  | 1     | `get_versions`                                                                                      |

441 of 467 projects with a measurable minor/patch diff dropped nothing from
their root namespace.

### What the ecosystem itself believes

Across 1,591,344 dependency requirements taken from the latest release of every
PyPI project published since 2024:

- 23.5% carry an upper bound of some kind;
- 9.8% are exact pins;
- 14.1% would refuse the dependency's current latest release (5.7% through a
  deliberate range cap, 8.4% through a stale exact pin).

Projects whose dependents most often cap below the current release, where a
resolver in the wild keeps landing on an older line no matter what the registry
offers:

| project               | dependents | capped | cap excludes latest | they land on              |
| --------------------- | ---------- | ------ | ------------------- | ------------------------- |
| `elasticsearch`       | 738        | 57.7%  | 36.6%               | 8.19.3, 7.17.13, 7.13.0   |
| `marshmallow`         | 610        | 64.4%  | 28.4%               | 3.26.2, 3.26.1, 3.19.0    |
| `moto`                | 682        | 44.4%  | 23.8%               | 5.2.1, 5.0.5, 4.2.14      |
| `protobuf`            | 4,292      | 50.3%  | 22.2%               | 6.33.6, 3.20.3, 5.29.6    |
| `wrapt`               | 919        | 51.5%  | 22.0%               | 1.17.3, 1.16.0, 1.17.2    |
| `chardet`             | 1,407      | 40.6%  | 21.6%               | 5.2.0, 3.0.4, 4.0.0       |
| `langfuse`            | 370        | 38.4%  | 21.4%               | 2.60.10, 3.15.0, 2.44.0   |
| `deepdiff`            | 526        | 35.7%  | 20.9%               | 8.6.2, 6.7.1, 7.0.1       |
| `gunicorn`            | 1,167      | 38.9%  | 20.7%               | 23.0.0, 21.2.0, 22.0.0    |
| `tokenizers`          | 1,143      | 42.7%  | 19.1%               | 0.21.4, 0.22.2, 0.19.1    |
| `redis`               | 5,403      | 27.1%  | 18.9%               | 5.3.1, 6.4.0, 7.4.1       |
| `pyspark`             | 912        | 41.0%  | 18.9%               | 3.5.9, 3.5.5, 3.5.1       |
| `sqlglot`             | 617        | 32.4%  | 18.8%               | 27.29.0, 26.33.0, 25.34.1 |
| `structlog`           | 2,118      | 25.8%  | 18.7%               | 25.5.0, 24.4.0, 23.3.0    |
| `langchain-community` | 1,748      | 39.0%  | 18.1%               | 0.3.31, 0.2.19, 0.4.1     |
| `cohere`              | 553        | 26.2%  | 17.9%               | 5.21.1, 6.1.0, 4.57       |
| `docstring-parser`    | 505        | 38.0%  | 17.8%               | 0.16, 0.15, 0.17.0        |
| `django`              | 6,634      | 23.5%  | 17.6%               | 5.2.17, 4.2.30, 6.0.8     |
| `websockets`          | 4,664      | 26.0%  | 17.4%               | 15.0.1, 12.0, 13.1        |
| `sqlalchemy-utils`    | 317        | 40.4%  | 17.4%               | 0.41.2, 0.38.3, 0.41.1    |

## (c) What to build, and what to point at something newer

5323 (project, version) pairs hold at least 2% of their project's traffic while
not being the latest release. Together they are 36.8% of all install traffic in
the survey. Verdict is whether serving the project's current latest instead
would break the caller:

| verdict       | pairs | share of that traffic | meaning                                                              |
| ------------- | ----- | --------------------- | -------------------------------------------------------------------- |
| safe          | 1147  | 45.6%                 | no public name removed, no signature narrowed                        |
| probably-safe | 319   | 11.6%                 | removals only below the root namespace and under 0.5% of the surface |
| breaking      | 651   | 20.6%                 | root-namespace names removed, or removals above tolerance            |
| unknown       | 104   | 2.5%                  | compiled-only wheel, no Python API to compare                        |
| unmeasured    | 3102  | 19.7%                 | not in the diff set                                                  |

Of the traffic on versions that genuinely cannot be substituted, 30.4% is on
versions that ship native code, which are the expensive ones to build for WASIX.

### What each policy costs

| policy                                  | builds | installs served | needs substitution      |
| --------------------------------------- | ------ | --------------- | ----------------------- |
| top 1 version of every project          | 1,000  | 56.5%           | no, exact version match |
| top 2 versions of every project         | 2,000  | 68.3%           | no, exact version match |
| top 3 versions of every project         | 3,000  | 74.1%           | no, exact version match |
| top 5 versions of every project         | 5,000  | 80.3%           | no, exact version match |
| top 8 versions of every project         | 8,000  | 85.1%           | no, exact version match |
| head of every major line above 5% share | 1,439  | 98.5%           | yes, within the line    |
| head of every major line above 2% share | 1,629  | 99.4%           | yes, within the line    |
| head of every major line above 1% share | 1,805  | 99.7%           | yes, within the line    |

The head-of-line policies only reach those numbers if serving a newer release
from the same line is acceptable. Measured against the diff, that assumption
fails for 2.9% of same-major pairs, carrying 4.6% of same-major traffic. Small,
but not zero, and concentrated in a nameable set of projects (the minor/patch
table above).

### Build these

Ranked by install volume. A version lands here when the latest release drops a
name from its top-level namespace, removes or narrows enough elsewhere to clear
the tolerance, or ships no Python API to compare. `pinned dependents` counts
published projects whose own metadata forbids the latest release and resolves to
exactly this version.

| project              | version   | latest    | share | age  | build  | boundary | dropped from root | names removed | signatures narrowed | pinned dependents |
| -------------------- | --------- | --------- | ----- | ---- | ------ | -------- | ----------------- | ------------- | ------------------- | ----------------- |
| `pytest`             | 8.4.1     | 9.1.1     | 27.1% | 1.1y | pure   | major    | 1                 | 1             | 0                   | 126               |
| `protobuf`           | 6.33.6    | 7.35.1    | 31.8% | 0.4y | native | major    | 0                 | 1             | 8                   | 339               |
| `urllib3`            | 1.26.20   | 2.7.0     | 12.5% | 1.9y | pure   | major    | 1                 | 179           | 7                   | 538               |
| `pandas`             | 2.3.3     | 3.0.5     | 25.9% | 0.9y | native | major    | 2                 | 260           | 114                 | 4705              |
| `importlib-metadata` | 8.7.1     | 9.0.0     | 32.6% | 0.6y | pure   | major    | 0                 | 3             | 0                   | 38                |
| `numpy`              | 1.26.4    | 2.5.2     | 14.5% | 2.5y | native | major    | 5                 | 770           | 2                   | 5663              |
| `rpds-py`            | 0.30.0    | 2026.6.3  | 26.4% | 0.7y | native | major    | ?                 | ?             | ?                   | 75                |
| `wrapt`              | 1.17.3    | 2.3.0     | 33.6% | 1.0y | native | major    | 1                 | 15            | 5                   | 211               |
| `mpmath`             | 1.3.0     | 1.4.1     | 97.8% | 3.4y | pure   | minor    | 2                 | 298           | 5                   | 233               |
| `websockets`         | 15.0.1    | 17.0.1    | 28.5% | 1.4y | native | major    | 0                 | 32            | 8                   | 346               |
| `requests`           | 2.32.5    | 2.34.2    | 9.1%  | 1.0y | pure   | minor    | 3                 | 10            | 0                   | 772               |
| `charset-normalizer` | 3.4.7     | 3.4.9     | 8.3%  | 0.4y | native | patch    | 0                 | 5             | 0                   | 59                |
| `websockets`         | 16.1.1    | 17.0.1    | 23.9% | 0.1y | native | major    | 0                 | 29            | 5                   | 142               |
| `hf-xet`             | 1.5.2     | 1.6.0     | 42.2% | 0.1y | native | minor    | ?                 | ?             | ?                   | 2                 |
| `pycparser`          | 2.23      | 3.0       | 10.6% | 0.9y | pure   | major    | 0                 | 555           | 0                   | 93                |
| `mcp`                | 1.28.1    | 2.0.0     | 34.6% | 0.1y | pure   | major    | 1                 | 1139          | 15                  | 33                |
| `pytest`             | 9.0.3     | 9.1.1     | 10.4% | 0.3y | pure   | minor    | 1                 | 1             | 0                   | 307               |
| `numpy`              | 2.2.6     | 2.5.2     | 9.6%  | 1.2y | native | minor    | 0                 | 48            | 2                   | 528               |
| `packaging`          | 25.0      | 26.3      | 4.7%  | 1.3y | pure   | major    | 0                 | 21            | 0                   | 466               |
| `protobuf`           | 5.29.6    | 7.35.1    | 11.6% | 0.5y | native | major    | 0                 | 26            | 7                   | 266               |
| `requests`           | 2.33.1    | 2.34.2    | 5.8%  | 0.4y | pure   | minor    | 3                 | 9             | 0                   | 147               |
| `websockets`         | 16.0      | 17.0.1    | 17.5% | 0.6y | native | major    | 0                 | 29            | 5                   | 54                |
| `cryptography`       | 48.0.1    | 50.0.0    | 6.5%  | 0.2y | native | major    | 0                 | 8             | 0                   | 146               |
| `click`              | 8.1.8     | 8.4.2     | 8.6%  | 1.6y | pure   | minor    | 4                 | 60            | 3                   | 612               |
| `requests`           | 2.31.0    | 2.34.2    | 5.3%  | 3.2y | pure   | minor    | 3                 | 11            | 0                   | 1003              |
| `docutils`           | 0.19      | 0.23      | 41.9% | 4.1y | pure   | minor    | 0                 | 102           | 12                  | 21                |
| `importlib-metadata` | 8.9.0     | 9.0.0     | 16.0% | 0.4y | pure   | major    | 7                 | 7             | 0                   | 93                |
| `marshmallow`        | 3.26.2    | 4.3.1     | 67.8% | 0.6y | pure   | major    | 1                 | 39            | 14                  | 170               |
| `packaging`          | 26.0      | 26.3      | 3.7%  | 0.5y | pure   | minor    | 0                 | 21            | 0                   | 71                |
| `coverage`           | 7.15.2    | 7.15.4    | 25.0% | 0.1y | native | patch    | 0                 | 5             | 0                   | 0                 |
| `boto3`              | 1.42.97   | 1.43.67   | 2.3%  | 0.3y | pure   | minor    | 0                 | 3             | 0                   | 13                |
| `pytest`             | 8.4.2     | 9.1.1     | 7.5%  | 0.9y | pure   | major    | 1                 | 1             | 0                   | 2535              |
| `requests`           | 2.32.4    | 2.34.2    | 4.4%  | 1.2y | pure   | minor    | 3                 | 10            | 0                   | 242               |
| `s3transfer`         | 0.10.4    | 0.19.2    | 8.2%  | 1.7y | pure   | minor    | 2                 | 2             | 0                   | 15                |
| `chardet`            | 5.2.0     | 7.5.1     | 32.9% | 3.0y | pure   | major    | 1                 | 537           | 0                   | 394               |
| `requests`           | 2.32.3    | 2.34.2    | 4.1%  | 2.2y | pure   | minor    | 3                 | 10            | 0                   | 1179              |
| `librt`              | 0.13.0    | 0.15.0    | 46.1% | 0.1y | native | minor    | ?                 | ?             | ?                   | 4                 |
| `cryptography`       | 46.0.7    | 50.0.0    | 4.8%  | 0.3y | native | major    | 0                 | 113           | 0                   | 239               |
| `regex`              | 2026.7.10 | 2026.7.19 | 15.2% | 0.1y | native | patch    | ?                 | ?             | ?                   | 0                 |
| `numpy`              | 2.0.2     | 2.5.2     | 6.0%  | 2.0y | native | minor    | 0                 | 50            | 2                   | 215               |
| `websockets`         | 16.1      | 17.0.1    | 12.0% | 0.1y | native | major    | 0                 | 29            | 5                   | 0                 |
| `fastapi`            | 0.139.2   | 0.141.1   | 11.6% | 0.1y | pure   | minor    | 0                 | 9             | 0                   | 41                |
| `s3transfer`         | 0.11.5    | 0.19.2    | 7.5%  | 1.3y | pure   | minor    | 2                 | 2             | 0                   | 0                 |
| `cachetools`         | 5.5.2     | 7.1.7     | 19.2% | 1.5y | pure   | major    | 3                 | 4             | 0                   | 248               |
| `charset-normalizer` | 3.4.4     | 3.4.9     | 3.8%  | 0.8y | native | patch    | 0                 | 37            | 0                   | 88                |
| `tomlkit`            | 0.15.0    | 0.15.1    | 19.4% | 0.2y | pure   | patch    | 0                 | 14            | 0                   | 14                |
| `caio`               | 0.9.25    | 0.12.2    | 85.9% | 0.6y | native | minor    | 0                 | 5             | 0                   | 4                 |
| `botocore`           | 1.37.38   | 1.43.67   | 4.2%  | 1.3y | pure   | minor    | 2                 | 4             | 0                   | 11                |
| `fsspec`             | 2023.10.0 | 2026.7.0  | 6.6%  | 2.8y | pure   | major    | 0                 | 30            | 3                   | 0                 |
| `google-api-core`    | 2.31.0    | 2.34.0    | 12.4% | 0.2y | pure   | minor    | 0                 | 4             | 0                   | 0                 |
| `opentelemetry-sdk`  | 1.39.1    | 1.44.0    | 11.5% | 0.7y | pure   | minor    | 0                 | 9             | 0                   | 21                |
| `ast-serialize`      | 0.6.0     | 0.8.0     | 71.3% | 0.1y | native | minor    | ?                 | ?             | ?                   | 6                 |
| `rich`               | 14.3.3    | 15.0.0    | 9.3%  | 0.5y | pure   | major    | 0                 | 14            | 0                   | 57                |
| `gunicorn`           | 23.0.0    | 26.0.0    | 40.9% | 2.0y | pure   | major    | 0                 | 22            | 2                   | 199               |
| `protobuf`           | 4.25.9    | 7.35.1    | 6.4%  | 0.4y | native | major    | 0                 | 32            | 6                   | 146               |
| `cryptography`       | 47.0.0    | 50.0.0    | 3.8%  | 0.3y | native | major    | 0                 | 8             | 0                   | 0                 |
| `pandas`             | 2.2.3     | 3.0.5     | 7.2%  | 1.9y | native | major    | 2                 | 260           | 114                 | 987               |
| `pathspec`           | 0.12.1    | 1.1.1     | 7.5%  | 2.7y | pure   | major    | 2                 | 19            | 1                   | 211               |
| `google-api-core`    | 2.30.3    | 2.34.0    | 11.2% | 0.3y | pure   | minor    | 0                 | 4             | 0                   | 3                 |
| `scipy`              | 1.13.1    | 1.18.0    | 12.4% | 2.2y | native | minor    | 0                 | 1015          | 1                   | 358               |

### Point these at the latest

Highest-volume historical versions the current release can stand in for: nothing
dropped from the top-level namespace, and any deeper removal below the
tolerance.

| project                    | version   | latest       | share | boundary | names removed | verdict       |
| -------------------------- | --------- | ------------ | ----- | -------- | ------------- | ------------- |
| `packaging`                | 26.2      | 26.3         | 69.4% | minor    | 0             | safe          |
| `setuptools`               | 83.0.0    | 84.0.0       | 73.1% | major    | 0             | safe          |
| `cffi`                     | 2.1.0     | 2.1.1        | 56.7% | patch    | 0             | safe          |
| `pydantic-core`            | 2.46.4    | 2.48.0       | 64.7% | minor    | 0             | safe          |
| `cryptography`             | 49.0.0    | 50.0.0       | 39.9% | major    | 3             | probably-safe |
| `certifi`                  | 2026.6.17 | 2026.7.22    | 30.3% | minor    | 0             | safe          |
| `annotated-types`          | 0.7.0     | 0.8.0        | 55.7% | minor    | 0             | safe          |
| `starlette`                | 1.3.1     | 1.6.0        | 54.3% | minor    | 1             | probably-safe |
| `annotated-doc`            | 0.0.4     | 0.0.5        | 68.6% | patch    | 0             | safe          |
| `numpy`                    | 2.5.1     | 2.5.2        | 26.5% | patch    | 0             | safe          |
| `platformdirs`             | 4.11.0    | 4.11.1       | 39.0% | patch    | 0             | safe          |
| `pip`                      | 26.1.2    | 26.2.1       | 44.2% | minor    | 0             | safe          |
| `googleapis-common-protos` | 1.75.0    | 1.75.1       | 55.7% | patch    | 0             | safe          |
| `pydantic-settings`        | 2.14.2    | 2.15.0       | 60.9% | minor    | 1             | probably-safe |
| `typing-extensions`        | 4.15.0    | 4.16.0       | 14.1% | minor    | 2             | probably-safe |
| `cffi`                     | 2.0.0     | 2.1.1        | 18.3% | minor    | 0             | safe          |
| `pytest-json-ctrf`         | 0.3.5     | 0.5.3        | 84.3% | minor    | 1             | probably-safe |
| `uvicorn`                  | 0.51.0    | 0.52.1       | 32.8% | minor    | 0             | safe          |
| `soupsieve`                | 2.9.1     | 2.9.2        | 42.5% | patch    | 1             | probably-safe |
| `numpy`                    | 2.4.6     | 2.5.2        | 16.5% | minor    | 1             | probably-safe |
| `pytz`                     | 2026.2    | 2026.3.post1 | 34.3% | minor    | 0             | safe          |
| `aiohttp`                  | 3.14.1    | 3.14.3       | 25.3% | patch    | 2             | probably-safe |
| `yarl`                     | 1.24.2    | 1.24.5       | 24.0% | patch    | 0             | safe          |
| `platformdirs`             | 4.10.0    | 4.11.1       | 18.5% | minor    | 0             | safe          |
| `mako`                     | 1.3.12    | 1.4.1        | 69.3% | minor    | 1             | probably-safe |
| `google-auth`              | 2.56.2    | 2.56.3       | 24.0% | patch    | 0             | safe          |
| `urllib3`                  | 2.6.3     | 2.7.0        | 7.6%  | minor    | 0             | safe          |
| `fsspec`                   | 2026.6.0  | 2026.7.0     | 15.2% | minor    | 0             | safe          |
| `prompt-toolkit`           | 3.0.52    | 3.0.53       | 55.4% | patch    | 0             | safe          |
| `pydantic-core`            | 2.41.5    | 2.48.0       | 12.9% | minor    | 0             | safe          |
