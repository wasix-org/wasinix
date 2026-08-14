"""Part B/C: what the ecosystem's own version constraints say about each project.

For every requirement string targeting a surveyed project, work out whether it
admits the current latest release, and if not, which release it would resolve to.
"""

import gzip, json, os, sys
from packaging.requirements import Requirement, InvalidRequirement
from packaging.specifiers import SpecifierSet
from packaging.version import Version, InvalidVersion

HERE = os.path.dirname(os.path.abspath(__file__))
CACHE, DATA = f"{HERE}/../cache", f"{HERE}/../data"


def pv(s):
    try:
        return Version(s)
    except InvalidVersion:
        return None


def main():
    usage = json.load(open(f"{DATA}/usage.json"))
    reqs = json.load(open(f"{DATA}/requirements.json"))
    out = {}
    for p, u in usage.items():
        entries = reqs.get(p) or []
        with gzip.open(f"{CACHE}/{p}.json.gz", "rt") as fh:
            rel = json.load(fh)["rel"]
        vers = sorted({v for v in (pv(x) for x in rel) if v is not None})
        stable = [v for v in vers if not v.is_prerelease] or vers
        latest = pv(u["latest"])
        if latest is None or not stable:
            continue

        n_total = n_bad = n_capped = n_pinned = n_unbounded = 0
        excl_pin = excl_cap = 0
        resolves = {}
        for raw, n in entries:
            n_total += n
            try:
                r = Requirement(raw)
            except InvalidRequirement:
                n_bad += n
                continue
            spec = r.specifier
            has_upper = any(s.operator in ("<", "<=", "==", "~=", "===") for s in spec)
            if any(s.operator in ("==", "===") and "*" not in s.version for s in spec):
                n_pinned += n
            if has_upper:
                n_capped += n
            else:
                n_unbounded += n
            if latest not in spec:
                n_excl = n
                if any(s.operator in ("==", "===") for s in spec):
                    excl_pin += n
                else:
                    excl_cap += n
                ok = [v for v in stable if v in spec]
                best = str(max(ok)) if ok else None
                resolves[best] = resolves.get(best, 0) + n_excl

        excl = sum(resolves.values())
        out[p] = {
            "rank": u["rank"],
            "dependents": n_total,
            "unparseable": n_bad,
            "pct_capped": n_capped / n_total if n_total else None,
            "pct_pinned": n_pinned / n_total if n_total else None,
            "pct_excludes_latest": excl / n_total if n_total else None,
            "excludes_latest": excl,
            # an exact pin freezes a dependent's own metadata; a range cap is a
            # deliberate statement that the next line is expected to break
            "excludes_latest_by_pin": excl_pin,
            "excludes_latest_by_cap": excl_cap,
            "pct_excludes_latest_by_cap": excl_cap / n_total if n_total else None,
            # where the dependents that reject the latest release would land
            "resolves_to": dict(sorted(resolves.items(), key=lambda kv: -kv[1])[:15]),
        }
    json.dump(out, open(f"{DATA}/caps.json", "w"))
    print(f"{len(out)} projects", file=sys.stderr)


if __name__ == "__main__":
    main()
