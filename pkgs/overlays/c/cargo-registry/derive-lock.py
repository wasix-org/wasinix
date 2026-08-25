# Turn upstream's Cargo.lock (which dogfoods the overlay, pinning every fork as
# <crate>+wasix.N) into one fetchCargoVendor can use from crates.io: strip the
# +wasix.N suffix off every version and dep ref (the exact upstream versions, not
# re-resolved), and replace each fork checksum with the crates.io one from the
# sparse index. The vendor-time patches re-apply the fork content.
#
#   python3 derive-lock.py <upstream-Cargo.lock> > Cargo.lock
#
# Every crate that loses a +wasix suffix needs a matching patch; the set is
# printed to stderr so a bump can check coverage.
import json
import re
import sys
import urllib.request

import tomlkit

SUFFIX = re.compile(r"\+wasix\.\d+")


def index_path(name):
    n = name.lower()
    if len(n) == 1:
        return f"1/{n}"
    if len(n) == 2:
        return f"2/{n}"
    if len(n) == 3:
        return f"3/{n[0]}/{n}"
    return f"{n[:2]}/{n[2:4]}/{n}"


def stock_checksum(name, version):
    url = f"https://index.crates.io/{index_path(name)}"
    with urllib.request.urlopen(url) as r:
        for line in r.read().decode().splitlines():
            e = json.loads(line)
            if e["vers"] == version:
                return e["cksum"]
    raise SystemExit(f"derive-lock: {name} {version} not on crates.io")


doc = tomlkit.parse(open(sys.argv[1]).read())

# Crates pinned to a +wasix fork, keyed by their crates.io version.
forked = {
    (str(p["name"]), SUFFIX.sub("", str(p["version"])))
    for p in doc["package"]
    if "+wasix." in str(p["version"])
}

patched = []
for p in doc["package"]:
    p["version"] = SUFFIX.sub("", str(p["version"]))
    deps = p.get("dependencies")
    if deps is not None:
        for i, d in enumerate(deps):
            deps[i] = SUFFIX.sub("", str(d))
    key = (str(p["name"]), str(p["version"]))
    if key in forked:
        p["checksum"] = stock_checksum(*key)
        patched.append(f"{key[0]} {key[1]}")

sys.stderr.write(
    "+wasix crates in upstream's lock. Each needs a wasix-crate-patches entry\n"
    "or must build stock. Fork content cascades through crates like ring and\n"
    "rustix; crates our toolchain handles unpatched, like cc and getrandom,\n"
    "need none:\n  " + "\n  ".join(patched) + "\n"
)
sys.stdout.write(tomlkit.dumps(doc))
