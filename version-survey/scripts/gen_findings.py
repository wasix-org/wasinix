"""Render findings.md from the computed aggregates."""

import json, os

HERE = os.path.dirname(os.path.abspath(__file__))
DATA, OUT = f"{HERE}/../data", f"{HERE}/.."

P = json.load(open(f"{DATA}/page_data.json"))
A, B, C, meta = P["A"], P["B"], P["C"], P["meta"]
usage = json.load(open(f"{DATA}/usage.json"))
recs = json.load(open(f"{DATA}/recommend.json"))
caps = json.load(open(f"{DATA}/caps.json"))


def pc(x, d=1):
    return "n/a" if x is None else f"{x * 100:.{d}f}%"


def M(n):
    return f"{n / 1e6:,.0f}M" if n < 1e9 else f"{n / 1e9:,.1f}B"


L = []
w = L.append

w("# PyPI historical-version survey")
w("")
w(
    f"**Survey window: {A['window'][0]} to {A['window'][1]}** (30 days), top {A['n_projects']} "
    f"PyPI projects by installer traffic, {M(A['downloads'])} downloads."
)
w("")
w(
    "Three questions, for sizing a WASIX Python package registry that would carry more than "
    "one version per package:"
)
w("")
w("- **(a)** which non-latest versions are actually being installed;")
w(
    "- **(b)** which projects keep the semver promise, so a newer release can stand in for an older one;"
)
w(
    "- **(c)** which historical versions are worth building, and which can just resolve to something newer."
)
w("")

# ------------------------------------------------------------------ headline
w("## Headline")
w("")
w("| | |")
w("|---|---|")
w(
    f"| installs that were **not** the newest release available that day | **{pc(1 - A['timely_latest_share'])}** |"
)
w(
    f"| installs that are not the latest release as of the survey end | {pc(1 - A['latest_share'])} |"
)
w(
    f"| installs within the **major** line that was current that day | {pc(A['timely_same_major_share'])} |"
)
w(f"| installs within the latest **minor** line | {pc(A['same_minor_share'])} |")
w(
    f"| of the non-latest half, still inside the current major | {pc(A['nonlatest_within_major'])} |"
)
w(f"| of the non-latest half, on an older major | {pc(A['nonlatest_older_major'])} |")
w(
    f"| median age of the release actually installed | {A['installed_age_q']['p50']} days |"
)
w(
    f"| dependency requirements in the wild carrying an upper bound | {pc(B['dep_capped'])} |"
)
w(
    f"| dependency requirements that forbid the current latest | {pc(B['dep_excl_latest'])} "
    f"({pc(B['dep_excl_by_cap'])} by range cap, {pc(B['dep_excl_by_pin'])} by exact pin) |"
)
w("")
w(
    f"Two numbers, because the naive one is unfair to fast-moving projects: measured against "
    f'a fixed "latest" at the end of the window, {pc(1 - A["latest_share"])} of installs are '
    f"historical; measured against whatever was newest on the day of each install, "
    f"{pc(1 - A['timely_latest_share'])} are. Either way roughly nine tenths of traffic stays "
    f"inside the current major line, so the version tail is mostly **lag** rather than "
    f"**incompatibility**, and lag is the cheap case."
)
w("")

# ------------------------------------------------------------------ part A
w("## (a) Which non-latest versions are in use")
w("")
w("### Lag, measured fairly")
w("")
w(
    f'A 30-day window against a fixed "latest" punishes projects that release daily: boto3 '
    f"ships a new version most weekdays, so its current release owns one day of the window and "
    f"scores 0.4%. Recomputing each install against the release that was newest on the day it "
    f"happened, over {M(A['timely_covered'])} downloads, gives "
    f"**{pc(A['timely_latest_share'])} on the newest release** and "
    f"{pc(A['timely_same_major_share'])} inside the then-current major line. The rest of this "
    f"section uses the fixed-latest view, which is the one that matters for deciding what a "
    f"registry has to hold today."
)
w("")
w("### Concentration")
w("")
w("| versions packaged per project | share of installs served |")
w("|---|---|")
for row in A["coverage_curve"]:
    w(f"| top {row['k']} | {pc(row['share'])} |")
w("")
q = A["n90_q"]
w(
    f"Distinct versions needed to cover 90% of one project's installs: median {q['p50']}, "
    f"p75 {q['p75']}, p90 {q['p90']}."
)
w("")
q = A["latest_share_q"]
w(
    f"Per-project share of installs on the latest release, unweighted: "
    f"p10 {pc(q['p10'])}, p25 {pc(q['p25'])}, median {pc(q['p50'])}, p75 {pc(q['p75'])}, "
    f"p90 {pc(q['p90'])}. The median project sees about half its installs on its newest release; "
    f"a quarter of projects see under {pc(q['p25'], 0)}."
)
w("")
w("### How old is the historical traffic")
w("")
b = A["age_buckets"]
tb = sum(b.values()) or 1
w(
    "Non-latest versions holding at least 2% of their project's traffic, "
    "bucketed by the age of the release being installed:"
)
w("")
w("| age of the installed release | share of that traffic |")
w("|---|---|")
w(f"| under 6 months | {pc(b['lt6m'] / tb)} |")
w(f"| 6 months to 2 years | {pc(b['6m_2y'] / tb)} |")
w(f"| over 2 years | {pc(b['gt2y'] / tb)} |")
w("")
w(
    f"Installs on the latest release come from Python >=3.12 {pc(A['python_modern_latest'])} of "
    f"the time; installs of older releases {pc(A['python_modern_old'])} of the time. Old-version "
    f"demand is not mostly an old-interpreter artefact."
)
w("")
w("### Projects with a genuinely live older major line")
w("")
w(
    f"{len(A['live_major_lines'])} projects (of {A['n_projects']}) send at least 10% of their "
    f"installs to a major other than the current one, on at least 100M installs. These are the "
    f"real multi-version packages:"
)
w("")
w("| project | latest | off-current-major | build | traffic by major |")
w("|---|---|---|---|---|")
for r in A["live_major_lines"][:30]:
    mj = ", ".join(f"{k}: {pc(v, 0)}" for k, v in list(r["majors"].items())[:4])
    w(
        f"| `{r['project']}` | {r['latest']} | {pc(r['off_major'])} | "
        f"{'native' if r['native'] else 'pure'} | {mj} |"
    )
w("")

# ------------------------------------------------------------------ part B
w("## (b) Who keeps the semver promise")
w("")
w("### Declared scheme")
w("")
w(
    "| scheme | projects | share of traffic | on latest | within latest major | dependents capping it | caps that exclude latest |"
)
w("|---|---|---|---|---|---|---|")
for k, v in sorted(B["schemes"].items(), key=lambda kv: -kv[1]["traffic"]):
    w(
        f"| {k} | {v['n']} | {pc(v['traffic_share'])} | {pc(v['latest'])} | {pc(v['in_major'])} | "
        f"{pc(v['capped'])} | {pc(v['cap_excl'])} |"
    )
w("")
q = B["major_bumps_per_year_q"]
w(
    f"Major bumps per year: median {q['p50']:.2f}, p75 {q['p75']:.2f}, p90 {q['p90']:.2f}. "
    f"{B['never_bumped_major']} of {B['semver_shaped_n']} semver-shaped projects have never "
    f'bumped a major at all, so for those "no major bump" cannot mean "no breaking change".'
)
w("")
w(
    "### Measured breakage: public API removed between the installed version and the latest"
)
w("")
w(
    "Every in-use version above 2% share was diffed against its project's current latest by "
    "AST-parsing both wheels and comparing the exported names. A removal means the newer "
    "release cannot silently stand in for the older one."
)
w("")
w("| boundary crossed | diffs | any API removed or narrowed | root namespace broken |")
w("|---|---|---|---|")
for k in ("patch", "minor", "major", "same", "unknown"):
    v = B["boundaries"].get(k)
    if not v:
        continue
    w(
        f"| {k} | {v['n']} | {pc(v['broke'] / v['n'])} | {pc(v['root_broke'] / v['n'])} |"
    )
w("")
mn = B["boundaries"].get("minor", {})
pt = B["boundaries"].get("patch", {})
mj = B["boundaries"].get("major", {})
if mn and pt and mj:
    w(
        f"The gradient is real: a major bump removes a root-namespace name "
        f"{pc(mj['root_broke'] / mj['n'])} of the time, a minor bump "
        f"{pc(mn['root_broke'] / mn['n'])}, a patch bump {pc(pt['root_broke'] / pt['n'])}. "
        f"So the major number does carry signal, but a minor bump breaking the top-level "
        f"namespace one time in {round(mn['n'] / max(mn['root_broke'], 1))} is too often to "
        f'treat "same major" as a substitution guarantee on its own.'
    )
w("")
w(
    "### Worst non-major breakage seen (minor or patch boundary, names dropped from the root namespace)"
)
w("")
w(
    "| project | latest | diffs at minor/patch | with root removals | worst | names dropped |"
)
w("|---|---|---|---|---|---|")
for r in [h for h in B["honesty"] if h["worst"] > 0][:25]:
    ex = ", ".join(f"`{x}`" for x in r["examples"][:4])
    w(
        f"| `{r['project']}` | {r['latest']} | {r['n']} | {r['bad']} | {r['worst']} | {ex} |"
    )
w("")
clean = [h for h in B["honesty"] if h["worst"] == 0]
w(
    f"{len(clean)} of {len(B['honesty'])} projects with a measurable minor/patch diff dropped "
    f"nothing from their root namespace."
)
w("")
w("### What the ecosystem itself believes")
w("")
w(
    f"Across {B['dep_total']:,} dependency requirements taken from the latest release of every "
    f"PyPI project published since 2024:"
)
w("")
w(f"- {pc(B['dep_capped'])} carry an upper bound of some kind;")
w(f"- {pc(B['dep_pinned'])} are exact pins;")
w(
    f"- {pc(B['dep_excl_latest'])} would refuse the dependency's current latest release "
    f"({pc(B['dep_excl_by_cap'])} through a deliberate range cap, {pc(B['dep_excl_by_pin'])} "
    f"through a stale exact pin)."
)
w("")
w(
    "Projects whose dependents most often cap below the current release, where a resolver in "
    "the wild keeps landing on an older line no matter what the registry offers:"
)
w("")
w("| project | dependents | capped | cap excludes latest | they land on |")
w("|---|---|---|---|---|")
for r in B["top_capped"][:20]:
    land = ", ".join(list(r["resolves_to"])[:3])
    w(
        f"| `{r['project']}` | {r['dependents']:,} | {pc(r['pct_capped'])} | "
        f"{pc(r['pct_excludes_latest_by_cap'])} | {land} |"
    )
w("")

# ------------------------------------------------------------------ part C
w("## (c) What to build, and what to point at something newer")
w("")
v = C["verdicts"]
tv = sum(x["downloads"] for x in v.values()) or 1
w(
    f"{C['n_pairs']} (project, version) pairs hold at least 2% of their project's traffic while "
    f"not being the latest release. Together they are {pc(C['rec_share_all'])} of all install "
    f"traffic in the survey. Verdict is whether serving the project's current latest instead "
    f"would break the caller:"
)
w("")
w("| verdict | pairs | share of that traffic | meaning |")
w("|---|---|---|---|")
labels = {
    "safe": "no public name removed, no signature narrowed",
    "probably-safe": "removals only below the root namespace and under 0.5% of the surface",
    "breaking": "root-namespace names removed, or removals above tolerance",
    "unknown": "compiled-only wheel, no Python API to compare",
    "unmeasured": "not in the diff set",
}
for k in ("safe", "probably-safe", "breaking", "unknown", "unmeasured"):
    if k not in v:
        continue
    w(f"| {k} | {v[k]['n']} | {pc(v[k]['downloads'] / tv)} | {labels[k]} |")
w("")
w(
    f"Of the traffic on versions that genuinely cannot be substituted, {pc(C['breaking_native_share'])} "
    f"is on versions that ship native code, which are the expensive ones to build for WASIX."
)
w("")
w("### What each policy costs")
w("")
w("| policy | builds | installs served | needs substitution |")
w("|---|---|---|---|")
for p in C["policies"]:
    w(
        f"| {p['name']} | {p['builds']:,} | {pc(p['served'])} | "
        f"{'no, exact version match' if p['exact'] else 'yes, within the line'} |"
    )
w("")
w(
    f"The head-of-line policies only reach those numbers if serving a newer release from the "
    f"same line is acceptable. Measured against the diff, that assumption fails for "
    f"{pc(C['within_line_break_pairs'])} of same-major pairs, carrying "
    f"{pc(C['within_line_break_traffic'])} of same-major traffic. Small, but not zero, and "
    f"concentrated in a nameable set of projects (the minor/patch table above)."
)
w("")
w("### Build these")
w("")
w(
    "Ranked by install volume. A version lands here when the latest release drops a name from "
    "its top-level namespace, removes or narrows enough elsewhere to clear the tolerance, or "
    "ships no Python API to compare. `pinned dependents` counts published projects whose own "
    "metadata forbids the latest release and resolves to exactly this version."
)
w("")
w(
    "| project | version | latest | share | age | build | boundary | dropped from root | names removed | signatures narrowed | pinned dependents |"
)
w("|---|---|---|---|---|---|---|---|---|---|---|")
for r in C["package_list"][:60]:
    age = f"{r['age_days'] / 365:.1f}y" if r["age_days"] else "?"
    n = lambda k: r[k] if r[k] is not None else "?"
    w(
        f"| `{r['project']}` | {r['version']} | {r['latest']} | {pc(r['share'])} | {age} | "
        f"{'native' if r['native'] else 'pure'} | {r['boundary'] or '?'} | "
        f"{n('removed_root')} | {n('removed')} | {n('narrowed')} | {r['pinned_dependents']} |"
    )
w("")
w("### Point these at the latest")
w("")
w(
    "Highest-volume historical versions the current release can stand in for: nothing dropped "
    "from the top-level namespace, and any deeper removal below the tolerance."
)
w("")
w("| project | version | latest | share | boundary | names removed | verdict |")
w("|---|---|---|---|---|---|---|")
for r in C["alias_list"][:30]:
    w(
        f"| `{r['project']}` | {r['version']} | {r['latest']} | {pc(r['share'])} | "
        f"{r['boundary'] or '?'} | {r['removed'] if r['removed'] is not None else '?'} | "
        f"{r['verdict']} |"
    )
w("")

open(f"{OUT}/findings.md", "w").write("\n".join(L) + "\n")
print(f"wrote findings.md ({len(L)} lines)")
