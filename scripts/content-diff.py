#!/usr/bin/env python3
# Of the outputs that were rebuilt (drvPath moved vs base), which actually
# changed content? Poor man's CA early-cutoff report, run after the build:
#
#   narHash(old) == narHash(new)          -> identical, no download needed
#   no self-references on either side     -> narHash differs means changed
#   self-references                       -> fetch both, normalize with
#                                            `nix store make-content-addressed`,
#                                            compare the rewritten paths
#
# "identical" is the strong signal. "changed" may just be a rebuilt dep's
# store path embedded in an otherwise-equal output; real CA derivations would
# cut that off, but they are off the table for now (docs/architecture.md).
#
# Old outputs come from the cache (present when the base commit's CI run
# pushed them); new ones from the local store, with a cache fallback for
# builds skipped by --skip-cached.

import argparse
import json
import subprocess
import sys

CACHE_URL = "https://nix-cache.wasix.org"
CACHE_PUB_KEY = "wasinix-1:jvsqbOJGsZxMvg97fuyNCWCc+t2nn6uHB47kQCGNmXI="
NARINFO_CHUNK = 100
# make-content-addressed downloads and copies both sides; keep that bounded
MAX_NORMALIZE = 25
NAR_SIZE_CAP = 256 * 1024 * 1024
LIST_CAP = 250


def log(msg):
    print(msg, file=sys.stderr)


def path_infos(paths, store=None):
    # -> {basename: narinfo|None}; chunked, tolerant of a failing invocation
    infos = {}
    for i in range(0, len(paths), NARINFO_CHUNK):
        chunk = paths[i : i + NARINFO_CHUNK]
        cmd = ["nix", "path-info", "--json", "--json-format", "2"]
        if store:
            cmd += ["--store", store]
        p = subprocess.run(cmd + chunk, capture_output=True, text=True)
        if p.returncode != 0:
            log(f"WARN: path-info failed for a chunk: {p.stderr.strip()[:200]}")
            infos.update({basename(pth): None for pth in chunk})
            continue
        infos.update(json.loads(p.stdout)["info"])
    return infos


def basename(path):
    return path.rsplit("/", 1)[-1]


def self_referential(path, info):
    return basename(path) in info.get("references", [])


def normalize_pair(old, new):
    # -> (identical, reason|None). Realise both (old substitutes from the
    # cache), then compare with self-references rewritten to content hashes.
    # explicit cache: raw nix-store does not read the flake's nixConfig
    r = subprocess.run(
        ["nix-store", "--realise", old, new,
         "--option", "extra-substituters", CACHE_URL,
         "--option", "extra-trusted-public-keys", CACHE_PUB_KEY],
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        return None, f"realise failed: {r.stderr.strip().splitlines()[-1][:120]}"
    p = subprocess.run(
        ["nix", "store", "make-content-addressed", "--json", old, new],
        capture_output=True, text=True,
    )
    if p.returncode != 0:
        return None, f"normalize failed: {p.stderr.strip().splitlines()[-1][:120]}"
    rw = json.loads(p.stdout)["rewrites"]
    return rw[old] == rw[new], None


def compare_all(pairs):
    olds = path_infos([p["old"] for p in pairs], store=CACHE_URL)
    news_local = path_infos([p["new"] for p in pairs])
    # --skip-cached builds may exist only in the cache, not locally
    missing = [p["new"] for p in pairs if not news_local.get(basename(p["new"]))]
    news_remote = path_infos(missing, store=CACHE_URL) if missing else {}

    identical, changed, skipped = [], [], []
    normalized = 0
    for p in pairs:
        old_info = olds.get(basename(p["old"]))
        new_info = news_local.get(basename(p["new"])) or news_remote.get(
            basename(p["new"])
        )
        if p["old"] == p["new"]:
            identical.append(p)
        elif old_info is None or new_info is None:
            side = "base" if old_info is None else "new"
            skipped.append((p, f"{side} output not available"))
        elif old_info["narHash"] == new_info["narHash"]:
            identical.append(p)
        elif not (
            self_referential(p["old"], old_info)
            or self_referential(p["new"], new_info)
        ):
            changed.append(p)
        elif max(old_info["narSize"], new_info["narSize"]) > NAR_SIZE_CAP:
            skipped.append((p, "self-referential and too large to normalize"))
        elif normalized >= MAX_NORMALIZE:
            skipped.append((p, f"normalize cap ({MAX_NORMALIZE}) reached"))
        else:
            normalized += 1
            same, reason = normalize_pair(p["old"], p["new"])
            if same is None:
                skipped.append((p, reason))
            elif same:
                identical.append(p)
            else:
                changed.append(p)
    return identical, changed, skipped


def section(title, lines, open_=False):
    if not lines:
        return ""
    shown = lines[:LIST_CAP]
    body = "\n".join(shown)
    if len(lines) > len(shown):
        body += f"\n- ... and {len(lines) - len(shown)} more"
    o = " open" if open_ else ""
    return f"\n<details{o}><summary>{title} ({len(lines)})</summary>\n\n{body}\n\n</details>\n"


def label(p):
    out = f"^{p['output']}" if p["output"] != "out" else ""
    return f"`{p['attr']}{out}`"


def render(pairs, identical, changed, skipped):
    md = "### Content diff\n\n"
    md += (
        f"Of **{len(pairs)}** rebuilt outputs: **{len(identical)}** bit-identical"
        f" · **{len(changed)}** changed · {len(skipped)} not comparable\n\n"
        "Identical is definitive. Changed may only be rebuilt store paths"
        " embedded in an otherwise-equal output.\n"
    )
    md += section("Changed", [f"- {label(p)}" for p in changed], open_=len(changed) <= 20)
    md += section("Bit-identical", [f"- {label(p)}" for p in identical])
    md += section("Not comparable", [f"- {label(p)}: {r}" for p, r in skipped])
    return md


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base-map", required=True)
    ap.add_argument("--head-map", required=True)
    ap.add_argument("--md-out", required=True)
    ap.add_argument("--summary-out", required=True)
    args = ap.parse_args()

    def done(md, summary):
        with open(args.md_out, "w") as f:
            f.write(md)
        with open(args.summary_out, "w") as f:
            json.dump(summary, f)

    try:
        with open(args.base_map) as f:
            base = json.load(f)
    except OSError:
        return done("### Content diff\n\nSkipped: no base eval map.\n", {})
    with open(args.head_map) as f:
        head = json.load(f)

    rebuilt = sorted(
        a
        for a in head["jobs"].keys() & base["jobs"].keys()
        if head["jobs"][a] != base["jobs"][a]
    )
    pairs = [
        {"attr": a, "output": name, "old": old, "new": new}
        for a in rebuilt
        for name, new in head.get("outputs", {}).get(a, {}).items()
        for old in [base.get("outputs", {}).get(a, {}).get(name)]
        if old and new
    ]
    if not pairs:
        return done(
            "### Content diff\n\nNothing rebuilt; no outputs to compare.\n",
            {"pairs": 0, "identical": 0, "changed": 0, "skipped": 0},
        )

    identical, changed, skipped = compare_all(pairs)
    log(f"{len(pairs)} pairs: {len(identical)} identical, {len(changed)} changed, {len(skipped)} skipped")
    done(
        render(pairs, identical, changed, skipped),
        {
            "pairs": len(pairs),
            "identical": len(identical),
            "changed": len(changed),
            "skipped": len(skipped),
        },
    )


if __name__ == "__main__":
    main()
