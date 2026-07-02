#!/usr/bin/env python3
# Auto-update the source pins of packages defined in this repo (the ones with
# their own upstream, not the `prev.X` nixpkgs passthroughs). Three backends:
#
#   nix-update  — for clean single-`src` derivations reachable as flake attrs.
#                 Discovers the new version, refills src hash + cargoHash by
#                 building. Used for crabsay.
#
#   prefetch    — for bare-string pins (a `version`/`rev` literal + a separate
#                 `hash`, where nix-update's strict eval can't introspect the
#                 package): rust-toolchain, cargo-wasix, wasix-libc, llvm,
#                 libffi. Reads the current literal, resolves the latest
#                 upstream tag (or branch HEAD), prefetches the new hash, and
#                 does an exact string swap so the explanatory comments survive.
#
#   flake       — `nix flake update <input>`: nixpkgs, wasmer, treefmt-nix.
#
# Derived files ride along automatically via per-target `regen` hooks:
# cargo-wasix's committed Cargo.lock is regenerated, the rust fork's stage0
# bootstrap pin is synced from its src/stage0, and wasix-libc's witx submodule
# pins are synced to the new tag. (wasixcc has no target — it pins a commit,
# not a release; see docs/tasks/update-wasixcc.md.)
#
# Usage (or `nix run .#update -- …`):
#   scripts/update.py              # update everything
#   scripts/update.py --only llvm wasix-libc
#   scripts/update.py --list       # show targets + current pins, no changes

import argparse
import json
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
from dataclasses import dataclass, field
from pathlib import Path
from urllib import request

SYSTEM = "x86_64-linux"


def run(cmd, **kw):
    print(f"  $ {' '.join(cmd)}", file=sys.stderr)
    p = subprocess.run(cmd, text=True, capture_output=True, **kw)
    if p.returncode != 0:
        raise RuntimeError(
            f"{cmd[0]} exited {p.returncode}:\n{(p.stderr or p.stdout).strip()}")
    return p


def repo_root():
    # Prefer the git working tree: under `nix run .#update` this file lives in the
    # store, but the pins we edit are in the checkout `nix run` was invoked from.
    try:
        out = subprocess.run(["git", "rev-parse", "--show-toplevel"],
                             check=True, text=True, capture_output=True)
        return Path(out.stdout.strip())
    except (subprocess.CalledProcessError, FileNotFoundError):
        return Path(__file__).resolve().parent.parent


REPO = repo_root()


def gh(path):
    req = request.Request(f"https://api.github.com/repos/{path}")
    req.add_header("Accept", "application/vnd.github+json")
    with request.urlopen(req) as r:
        return json.load(r)


def latest_release_tag(repo):
    return gh(f"{repo}/releases/latest")["tag_name"]


def default_branch_head(repo):
    info = gh(repo)
    branch = info["default_branch"]
    return gh(f"{repo}/branches/{branch}")["commit"]["sha"]


def prefetch_github(owner, repo, rev):
    url = f"https://github.com/{owner}/{repo}/archive/{rev}.tar.gz"
    out = run(["nix", "store", "prefetch-file", "--json", "--unpack", url])
    return json.loads(out.stdout)["hash"]


def prefetch_url(url):
    out = run(["nix", "store", "prefetch-file", "--json", url])
    return json.loads(out.stdout)["hash"]


def prefetch_github_submodules(owner, repo, rev):
    # `prefetch-file --unpack` hashes only the archive tarball, which omits
    # submodules; for fetchSubmodules=true (rust pulls src/llvm-project) we must
    # fetch the real tree. nix-prefetch-git --fetch-submodules computes exactly
    # the hash fetchFromGitHub verifies, and (unlike `import <nixpkgs>`) needs no
    # nixpkgs in the search path — which CI/flake eval doesn't provide.
    out = run(["nix-prefetch-git", "--quiet", "--fetch-submodules",
               "--url", f"https://github.com/{owner}/{repo}.git", "--rev", rev])
    return json.loads(out.stdout)["hash"]


def raw_file(owner, repo, rev, path):
    url = f"https://raw.githubusercontent.com/{owner}/{repo}/{rev}/{path}"
    with request.urlopen(url) as r:
        return r.read().decode()


def fetch_source(owner, repo, rev):
    # Download + unpack the github archive into a temp dir; returns the unpacked
    # root. (Archives omit submodules — fine for the lockfile/stage0 regens.)
    url = f"https://github.com/{owner}/{repo}/archive/{rev}.tar.gz"
    tmp = Path(tempfile.mkdtemp(prefix="wasinix-update-"))
    tarball = tmp / "src.tar.gz"
    with request.urlopen(url) as r, open(tarball, "wb") as f:
        shutil.copyfileobj(r, f)
    with tarfile.open(tarball) as t:
        t.extractall(tmp, filter="data")
    return next(p for p in tmp.iterdir() if p.is_dir())


@dataclass
class Target:
    name: str
    backend: str  # "nix-update" | "prefetch" | "flake"
    # flake: the flake.lock input name (`nix flake update <input>`)
    input: str = ""
    # nix-update:
    attr: str = ""
    version: str = ""  # "", "branch", or an explicit version
    filename: str = ""  # --override-filename when meta.position is absent
    # prefetch:
    file: str = ""
    owner: str = ""
    repo: str = ""
    kind: str = "github"  # "github" | "url"
    track: str = "release"  # "release" (latest tag) | "branch" (default-branch HEAD)
    submodules: bool = False  # fetchSubmodules=true → hash the real tree, not the archive
    # the literal currently holding the version/rev, captured so we can swap it
    version_re: str = ""
    # given the chosen tag, map it to (literal-to-write, rev-for-prefetch)
    tag_to_version: object = field(default=lambda t: (t, t))
    # for kind == "url": build the fetch URL from the version literal
    url_for: object = None
    # run after the pin bump to regenerate derived files (lockfile, bootstrap).
    # Takes the Target, returns a one-line summary or None if nothing changed.
    regen: object = None


def regen_cargo_wasix_lock(t):
    # cargo-wasix ships no Cargo.lock; we carry one and vendor from it. Resolve a
    # fresh lock against the just-bumped src so the offline build stays buildable.
    path = REPO / "pkgs/toolchain/rust/cargo-wasix.nix"
    version = re.search(r'version = "([^"]+)"', path.read_text()).group(1)
    src = fetch_source("wasix-org", "cargo-wasix", f"v{version}")
    run(["cargo", "generate-lockfile", "--manifest-path", str(src / "Cargo.toml")])
    dst = REPO / "pkgs/toolchain/rust/cargo-wasix.Cargo.lock"
    new = (src / "Cargo.lock").read_text()
    if dst.read_text() == new:
        return None
    dst.write_text(new)
    return f"regenerated cargo-wasix.Cargo.lock at v{version}"


def regen_rust_bootstrap(t):
    # The rust fork's vendoring auto-tracks the src lockfiles (no FOD hash). The
    # only pin that can drift is the stage0 bootstrap compiler, declared in the
    # fork's src/stage0 — sync version + url + hash from there.
    path = REPO / "pkgs/toolchain/rust/toolchain.nix"
    text = path.read_text()
    version = re.search(r'version = "([^"]+)"', text).group(1)
    stage0 = raw_file("wasix-org", "rust", f"v{version}", "src/stage0")
    kv = dict(re.findall(r"^(\w+)=(.+)$", stage0, re.M))
    date, ver, server = kv["compiler_date"], kv["compiler_version"], kv["dist_server"]

    cur = re.search(r'pname = "rust-bootstrap";\s*\n\s*version = "([^"]+)"', text).group(1)
    if cur == ver:
        return None

    url_literal = f'{server}/dist/{date}/rust-{ver}-${{hostTriple}}.tar.xz'
    new_hash = prefetch_url(
        f"{server}/dist/{date}/rust-{ver}-x86_64-unknown-linux-gnu.tar.xz")
    old_hash = re.search(r'rust-bootstrap";.*?(sha256-[A-Za-z0-9+/=]+)',
                         text, re.S).group(1)

    text = re.sub(r'(pname = "rust-bootstrap";\s*\n\s*version = ")[^"]+(")',
                  rf'\g<1>{ver}\g<2>', text)
    text = re.sub(r'url = "[^"]*rust-[^"]*\.tar\.xz";',
                  f'url = "{url_literal}";', text)
    text = text.replace(old_hash, new_hash, 1)
    path.write_text(text)
    return f"synced rust bootstrap -> {ver} ({date})"


def regen_libc_witx(t):
    # wasix-libc carries the wasi/wasix witx specs as git submodules; libc.nix
    # pins them separately (the header generators run from those, decoupled from
    # the libc src). A wasix-libc bump usually moves the wasix-witx submodule
    # (new syscalls), and a stale pin fails the libc build with undeclared
    # __wasi_* functions — so sync each pin to the submodule rev at the new tag.
    tag = re.search(r'wasixLibcVersion = "([^"]+)"',
                    (REPO / "pkgs/toolchain/sysroot/default.nix").read_text()).group(1)
    path = REPO / "pkgs/toolchain/sysroot/libc.nix"
    text = path.read_text()
    bumped = []
    for sub, owner, repo in [
        ("tools/wasi-headers/WASI", "WebAssembly", "WASI"),
        ("tools/wasix-headers/WASI", "wasix-org", "wasix-witx"),
    ]:
        sha = gh(f"wasix-org/wasix-libc/contents/{sub}?ref={tag}")["sha"]
        m = re.search(
            rf'repo = "{repo}";\s*\n\s*rev = "([^"]+)";\s*\n\s*hash = "([^"]+)"', text)
        if not m:
            raise RuntimeError(f"{repo}: witx pin block not found in libc.nix")
        if m.group(1) == sha:
            continue
        new_hash = prefetch_github(owner, repo, sha)
        text = text.replace(m.group(1), sha, 1).replace(m.group(2), new_hash, 1)
        bumped.append(f"{repo} -> {sha[:12]}")
    if not bumped:
        return None
    path.write_text(text)
    return "witx pins: " + ", ".join(bumped)


TARGETS = [
    # crabsay (a third-party demo) cuts no releases, so track its default branch.
    Target("crabsay", "nix-update",
           attr=f"legacyPackages.{SYSTEM}.shippedPackages.crabsay",
           version="branch"),
    # rust-toolchain: prefetch, not nix-update — its date+suffix fork tags
    # (v2026-…+rust-1.90) defeat nix-update's version heuristic (it strips the
    # `v` and looks up a tag that doesn't exist). fetchSubmodules pulls
    # src/llvm-project, so the hash covers the real tree, not the archive.
    Target("rust-toolchain", "prefetch",
           file="pkgs/toolchain/rust/toolchain.nix",
           owner="wasix-org", repo="rust", submodules=True,
           version_re=r'version = "([^"]+)"',
           tag_to_version=lambda t: (t.removeprefix("v"), t),
           regen=regen_rust_bootstrap),

    # The prefetch backend (no package eval) is used where nix-update's strict
    # eval can't introspect the package: libffi sets src inside overrideAttrs
    # (unsafeGetAttrPos returns null), and cargo-wasix derives its version from
    # the src via IFD. Both just need a literal swap + a re-prefetched hash.
    Target("libffi", "prefetch",
           file="pkgs/overlay/packages/libffi.nix",
           owner="wasix-org", repo="libffi", track="branch",
           version_re=r'rev = "([0-9a-f]{7,40})"'),
    Target("cargo-wasix", "prefetch",
           file="pkgs/toolchain/rust/cargo-wasix.nix",
           owner="wasix-org", repo="cargo-wasix",
           # version literal is bare (0.1.28); the release tag is v${version}.
           version_re=r'version = "([^"]+)"',
           tag_to_version=lambda t: (t.removeprefix("v"), t),
           regen=regen_cargo_wasix_lock),
    Target("wasix-libc", "prefetch",
           file="pkgs/toolchain/sysroot/default.nix",
           owner="wasix-org", repo="wasix-libc",
           version_re=r'wasixLibcVersion = "([^"]+)"',
           regen=regen_libc_witx),
    # llvm: bump the fork release tag + hash only. llvmVersion is the *base* LLVM
    # version that drives nixpkgs' patch selection and must not be touched.
    Target("llvm", "prefetch",
           file="pkgs/toolchain/llvm.nix",
           owner="wasix-org", repo="llvm-project",
           version_re=r'tag = "([0-9][^"]+)"; # fork release tag'),

    # Flake inputs (flake.lock). Each is its own target so `--only nixpkgs` works
    # like a package. nixpkgs drives the stdenv + every prev.X override package.
    Target("nixpkgs", "flake", input="nixpkgs"),
    Target("wasmer", "flake", input="wasmer"),
    Target("treefmt-nix", "flake", input="treefmt-nix"),
]


def update_nix_update(t):
    cmd = ["nix-update", "--flake"]
    if t.version:
        cmd.append(f"--version={t.version}")
    if t.filename:
        cmd += ["--override-filename", t.filename]
    cmd.append(t.attr)
    run(cmd, cwd=REPO)


def flake_input_rev(name):
    node = json.loads((REPO / "flake.lock").read_text())["nodes"][name]["locked"]
    return node.get("rev") or node.get("ref") or ""


def update_flake_input(t):
    before = flake_input_rev(t.input)
    run(["nix", "flake", "update", t.input], cwd=REPO)
    after = flake_input_rev(t.input)
    print(f"  {before[:10]} -> {after[:10]}" if before != after else "  up to date")


def update_prefetch(t):
    path = REPO / t.file
    text = path.read_text()
    m = re.search(t.version_re, text)
    if not m:
        raise SystemExit(f"{t.name}: version pattern not found in {t.file}")
    cur = m.group(1)

    if t.track == "branch":
        new_literal = rev = default_branch_head(f"{t.owner}/{t.repo}")
    else:
        new_literal, rev = t.tag_to_version(latest_release_tag(f"{t.owner}/{t.repo}"))
    if new_literal == cur:
        print(f"  up to date ({cur})")
        return False

    print(f"  {cur} -> {new_literal}")
    if t.kind == "url":
        new_hash = prefetch_url(t.url_for(new_literal))
    elif t.submodules:
        new_hash = prefetch_github_submodules(t.owner, t.repo, rev)
    else:
        new_hash = prefetch_github(t.owner, t.repo, rev)

    # swap the version literal (exact, via the captured span) and the old hash.
    old_hash = re.search(r'sha256-[A-Za-z0-9+/=]+', text[m.end():]).group(0)
    text = text[:m.start(1)] + new_literal + text[m.end(1):]
    text = text.replace(old_hash, new_hash, 1)
    path.write_text(text)
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", nargs="*", metavar="NAME")
    ap.add_argument("--list", action="store_true")
    args = ap.parse_args()

    targets = TARGETS
    if args.only:
        wanted = set(args.only)
        targets = [t for t in TARGETS if t.name in wanted]
        unknown = wanted - {t.name for t in targets}
        if unknown:
            raise SystemExit(f"unknown target(s): {', '.join(sorted(unknown))}")

    if args.list:
        for t in targets:
            print(f"{t.name:16} {t.backend}")
        return

    def repo_status():
        return subprocess.run(["git", "-C", str(REPO), "status", "--porcelain"],
                              text=True, capture_output=True).stdout

    backends = {
        "nix-update": update_nix_update,
        "prefetch": update_prefetch,
        "flake": update_flake_input,
    }

    # One flaky upstream must not abort the rest: isolate each target, collect
    # failures, and exit non-zero at the end so CI/the workflow notices.
    failures = []
    for t in targets:
        print(f"==> {t.name}")
        before = repo_status()
        try:
            backends[t.backend](t)
        except Exception as e:
            print(f"  FAILED: {e}")
            failures.append(t.name)
            continue
        # Run the regen only on an actual bump (the working tree changed).
        if t.regen and repo_status() != before:
            try:
                summary = t.regen(t)
                print(f"  regen: {summary or 'no derived changes'}")
            except Exception as e:
                print(f"  regen FAILED: {e}")
                failures.append(f"{t.name} (regen)")

    if failures:
        print(f"\nFAILED: {', '.join(failures)}")
        sys.exit(1)


if __name__ == "__main__":
    main()
