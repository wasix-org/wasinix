#!/usr/bin/env python3

# Build shipped webc packages and publish those the registry does not
# already have. Run from the repo root (`nix run .#scripts.publish-webc`).
# Packages publish in dependency order; a webc [dependencies] edge to a
# package that is neither published nor part of the run is an error.

import argparse
import hashlib
import json
import re
import shutil
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from urllib import error, parse, request

try:
    import tomllib
except ModuleNotFoundError as exc:
    raise SystemExit("Python 3.11+ is required (missing tomllib).") from exc


@dataclass(frozen=True)
class Package:
    full_name: str
    version: str
    path: Path
    # webc [dependencies]: full name -> version
    dependencies: dict[str, str]
    # [package.metadata] wasix-rel (source-manifest plumbing, WASIX-TODO.md)
    rel: int


@dataclass(frozen=True)
class PublishedPackageVersion:
    exists: bool
    webc_sha256: str | None
    readme: str | None


def run(
    cmd: list[str], *, cwd: Path | None = None, capture_stdout: bool = False
) -> subprocess.CompletedProcess[str]:
    print(f"+ {' '.join(cmd)}")
    return subprocess.run(
        cmd,
        cwd=str(cwd) if cwd else None,
        check=True,
        text=True,
        # stderr streams through so build progress stays visible
        stdout=subprocess.PIPE if capture_stdout else None,
    )


def build_pkg_roots(selected: list[str]) -> list[Path]:
    prefix = ".#legacyPackages.x86_64-linux"
    if selected:
        installables = [
            # quoted: webc names may contain dots (python3.14)
            f'{prefix}.wasmerPackages."{name}".pkg'
            for name in dict.fromkeys(selected)
        ]
    else:
        installables = [f"{prefix}.allWasmerPackages"]
    proc = run(
        [
            "nix",
            "build",
            "-L",
            "--accept-flake-config",
            "--no-link",
            "--print-out-paths",
            *installables,
        ],
        capture_stdout=True,
    )
    return [Path(line) / "pkg" for line in proc.stdout.split()]


def normalize_registry_url(registry: str) -> str:
    registry = registry.strip().rstrip("/")
    if registry.startswith("http://") or registry.startswith("https://"):
        return registry
    return f"https://{registry}"


def graphql_endpoint_for_registry(registry: str) -> str:
    normalized = normalize_registry_url(registry)
    parsed = parse.urlparse(normalized)
    if not parsed.netloc:
        raise SystemExit(f"Invalid registry value: {registry}")

    host = parsed.netloc
    scheme = parsed.scheme or "https"
    graphql_host = host if host.startswith("registry.") else f"registry.{host}"
    return f"{scheme}://{graphql_host}/graphql"


def publish_registry_for_wasmer(registry: str) -> str:
    normalized = normalize_registry_url(registry)
    parsed = parse.urlparse(normalized)
    if not parsed.netloc:
        raise SystemExit(f"Invalid registry value: {registry}")

    host = parsed.netloc
    if host.startswith("registry."):
        return host[len("registry.") :]
    return host


def read_packages(pkg_roots: list[Path]) -> dict[str, Package]:
    packages: dict[str, Package] = {}
    for pkg_root in pkg_roots:
        if not pkg_root.is_dir():
            raise SystemExit(f"Package directory does not exist: {pkg_root}")
        for toml_path in pkg_root.glob("**/wasmer.toml"):
            pkg_dir = toml_path.parent
            with toml_path.open("rb") as f:
                data = tomllib.load(f)

            package = data.get("package", {})
            full_name = package.get("name")
            version = package.get("version")
            if not isinstance(full_name, str) or not isinstance(version, str):
                raise SystemExit(
                    f"Missing/invalid package.name or package.version in {toml_path}"
                )

            dependencies = data.get("dependencies", {})
            if not isinstance(dependencies, dict) or any(
                not isinstance(k, str) or not isinstance(v, str)
                for k, v in dependencies.items()
            ):
                raise SystemExit(f"Invalid [dependencies] in {toml_path}")

            if full_name in packages:
                raise SystemExit(
                    f"Duplicate package name {full_name} in {toml_path} and {packages[full_name].path / 'wasmer.toml'}"
                )

            rel = package.get("metadata", {}).get("wasix-rel")
            packages[full_name] = Package(
                full_name=full_name,
                version=version,
                path=pkg_dir,
                dependencies=dependencies,
                rel=rel if isinstance(rel, int) else 1,
            )

    if not packages:
        raise SystemExit(f"No packages found under {pkg_roots}")

    return packages


def order_packages(packages: dict[str, Package]) -> list[Package]:
    # dependencies first, name order for determinism
    ordered: list[Package] = []
    done: set[str] = set()

    def visit(name: str, chain: tuple[str, ...]) -> None:
        if name in done:
            return
        if name in chain:
            raise SystemExit(f"Dependency cycle: {' -> '.join(chain + (name,))}")
        for dep in sorted(packages[name].dependencies):
            if dep in packages:
                visit(dep, chain + (name,))
        done.add(name)
        ordered.append(packages[name])

    for name in sorted(packages):
        visit(name, ())
    return ordered


def normalize_sha256(value: object) -> str | None:
    if not isinstance(value, str):
        return None
    candidate = value.strip().lower()
    if len(candidate) != 64:
        return None
    if any(ch not in "0123456789abcdef" for ch in candidate):
        return None
    return candidate


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        while True:
            chunk = f.read(1024 * 1024)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()


def build_webc_sha256(pkg_dir: Path, pkg: Package) -> str:
    with tempfile.TemporaryDirectory(prefix="publish-webc-") as tmpdir:
        out = Path(tmpdir) / "package.webc"
        run(
            ["wasmer", "package", "build", "--quiet", "--out", str(out), "."],
            cwd=pkg_dir,
        )
        if not out.is_file():
            raise SystemExit(
                f"Expected local .webc output missing for {pkg.full_name}@{pkg.version}: {out}"
            )
        return sha256_file(out)


def get_published_package_version(
    graphql_url: str, full_name: str, version: str
) -> PublishedPackageVersion:
    payload = {
        "query": (
            "query GetPackageVersion($name: String!, $version: String!) { "
            "getPackageVersion(name: $name, version: $version) { "
            "id "
            "readme "
            "distribution { webcSha256Hash piritaSha256Hash } "
            "packagewebcSet(first: 1) { edges { node { tag webc { webcSha256 } webcV3 { webcSha256 } } } } "
            "} "
            "}"
        ),
        "variables": {"name": full_name, "version": version},
        "operationName": "GetPackageVersion",
    }
    req = request.Request(
        graphql_url,
        data=json.dumps(payload).encode("utf-8"),
        headers={"content-type": "application/json"},
        method="POST",
    )
    try:
        with request.urlopen(req) as resp:
            body = resp.read().decode("utf-8")
    except error.HTTPError as exc:
        raise SystemExit(
            f"GraphQL request failed ({exc.code}) for {full_name}@{version}: {exc.reason}"
        ) from exc
    except error.URLError as exc:
        raise SystemExit(
            f"GraphQL request failed for {full_name}@{version}: {exc.reason}"
        ) from exc

    try:
        doc = json.loads(body)
    except json.JSONDecodeError as exc:
        raise SystemExit(
            f"Invalid GraphQL JSON response for {full_name}@{version}: {exc}"
        ) from exc

    if "errors" in doc and doc["errors"]:
        raise SystemExit(
            f"GraphQL returned errors for {full_name}@{version}: {doc['errors']}"
        )

    data = doc.get("data")
    if not isinstance(data, dict):
        raise SystemExit(
            f"GraphQL response missing data for {full_name}@{version}: {doc}"
        )

    package_version = data.get("getPackageVersion")
    if package_version is None:
        return PublishedPackageVersion(exists=False, webc_sha256=None, readme=None)
    if not isinstance(package_version, dict):
        raise SystemExit(
            f"GraphQL getPackageVersion has unexpected shape for {full_name}@{version}: {package_version}"
        )

    webc_sha256: str | None = None

    packagewebc_set = package_version.get("packagewebcSet")
    if isinstance(packagewebc_set, dict):
        edges = packagewebc_set.get("edges")
        if isinstance(edges, list):
            for edge in edges:
                if not isinstance(edge, dict):
                    continue
                node = edge.get("node")
                if not isinstance(node, dict):
                    continue
                webc_v3 = node.get("webcV3")
                if isinstance(webc_v3, dict):
                    webc_sha256 = normalize_sha256(webc_v3.get("webcSha256"))
                if webc_sha256 is None:
                    webc = node.get("webc")
                    if isinstance(webc, dict):
                        webc_sha256 = normalize_sha256(webc.get("webcSha256"))
                if webc_sha256 is None:
                    webc_sha256 = normalize_sha256(node.get("tag"))
                if webc_sha256 is not None:
                    break

    if webc_sha256 is None:
        distribution = package_version.get("distribution")
        if isinstance(distribution, dict):
            webc_sha256 = normalize_sha256(distribution.get("webcSha256Hash"))
            if webc_sha256 is None:
                webc_sha256 = normalize_sha256(distribution.get("piritaSha256Hash"))

    readme = package_version.get("readme")
    return PublishedPackageVersion(
        exists=True,
        webc_sha256=webc_sha256,
        readme=readme if isinstance(readme, str) else None,
    )


# The appended block is a pure function of (package dir, rev), so a later run
# reproduces the published bytes by restaging its local build with the
# recorded rev; keep it byte-stable or existing-version checks break.
REV_RE = re.compile(r"^- wasinix-rev: (\S+)$", re.M)


def recorded_rev(readme: str | None) -> str | None:
    if not readme:
        return None
    m = REV_RE.search(readme)
    return m.group(1) if m else None


def stage_with_provenance(pkg: Package, rev: str, tmpdir: str) -> Path:
    dst = Path(tmpdir) / "pkg"
    shutil.copytree(pkg.path, dst)
    for p in dst.rglob("*"):
        p.chmod(p.stat().st_mode | 0o200)
    name = pkg.full_name.split("/", 1)[1]
    with (dst / "README.md").open("a") as f:
        f.write(
            f"- wasinix-rev: {rev}\n"
            f"- rebuild: `nix build github:wasix-org/wasinix/{rev}"
            f'#wasmerPackages."{name}".webc`\n'
        )
    return dst


def staged_webc_sha256(pkg: Package, rev: str) -> str:
    with tempfile.TemporaryDirectory(prefix="publish-webc-") as tmpdir:
        return build_webc_sha256(stage_with_provenance(pkg, rev, tmpdir), pkg)


def verify_published(graphql_url: str, pkg: Package, expected_sha: str) -> None:
    # `wasmer publish` can exit 0 without tagging anything (WASIX-TODO.md), so
    # re-query until the version shows up; retries cover indexing lag.
    info = None
    for _ in range(5):
        info = get_published_package_version(graphql_url, pkg.full_name, pkg.version)
        if info.exists:
            break
        time.sleep(5)
    if info is None or not info.exists:
        raise SystemExit(
            f"wasmer publish reported success for {pkg.full_name}@{pkg.version}, "
            "but the version is not visible in the registry (silent no-op?)"
        )
    if info.webc_sha256 is not None and info.webc_sha256 != expected_sha:
        raise SystemExit(
            f"Published {pkg.full_name}@{pkg.version} but the registry stored "
            f"different content: local={expected_sha} registry={info.webc_sha256}"
        )
    if info.webc_sha256 is None:
        print(
            f"WARN: registry returned no hash for {pkg.full_name}@{pkg.version}; "
            "cannot cross-check the published content"
        )


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Build and publish shipped webc packages."
    )
    parser.add_argument(
        "--registry",
        required=True,
        help="Wasmer registry host or URL (e.g. wasmer.io or https://wasmer.io).",
    )
    parser.add_argument(
        "packages",
        nargs="*",
        metavar="NAME",
        help="webc names to publish (wasmerPackages attrs, e.g. bash git); none = all shipped.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Only print what would be published/skipped; do not publish anything.",
    )
    parser.add_argument(
        "--skip-sha-validation",
        action="store_true",
        help="Skip SHA-256 validation for package versions that already exist in the registry.",
    )
    parser.add_argument(
        "--rev",
        default="",
        help="wasinix git rev recorded in each published README (default: HEAD, -dirty suffixed).",
    )
    args = parser.parse_args()

    rev = args.rev
    if not rev:
        rev = run(["git", "rev-parse", "HEAD"], capture_stdout=True).stdout.strip()
        if subprocess.run(["git", "diff-index", "--quiet", "HEAD"]).returncode != 0:
            rev += "-dirty"

    packages = read_packages(build_pkg_roots(args.packages))
    ordered = order_packages(packages)

    graphql_url = graphql_endpoint_for_registry(args.registry)
    publish_registry = publish_registry_for_wasmer(args.registry)
    print(
        f"Discovered {len(ordered)} packages. Using registry: {args.registry} "
        f"(GraphQL: {graphql_url}, publish: {publish_registry})"
    )
    if args.dry_run:
        print("Dry-run mode enabled: no packages will be published.")
    if args.skip_sha_validation:
        print("SHA validation disabled for already-published package versions.")

    published = 0
    skipped = 0
    for pkg in ordered:
        published_info = get_published_package_version(
            graphql_url, pkg.full_name, pkg.version
        )
        if published_info.exists:
            if args.skip_sha_validation:
                print(
                    f"SKIP {pkg.full_name}@{pkg.version} path={pkg.path} "
                    "already exists (hash validation skipped)"
                )
                skipped += 1
                continue
            if published_info.webc_sha256 is None:
                raise SystemExit(
                    f"Cannot verify published hash for existing {pkg.full_name}@{pkg.version}; "
                    "registry response did not include a usable SHA-256 hash."
                )
            # the published artifact carries publish-time README lines;
            # restage the local build with the recorded rev to reproduce it
            # (artifacts published without provenance compare bare)
            published_rev = recorded_rev(published_info.readme)
            local_webc_sha256 = (
                staged_webc_sha256(pkg, published_rev)
                if published_rev is not None
                else build_webc_sha256(pkg.path, pkg)
            )
            if local_webc_sha256 != published_info.webc_sha256:
                raise SystemExit(
                    f"Hash mismatch for existing package {pkg.full_name}@{pkg.version}: "
                    f"local={local_webc_sha256} registry={published_info.webc_sha256}. "
                    "Registry versions are immutable and no webc rel encoding "
                    "exists yet (WASIX-TODO.md), so this version cannot be "
                    "republished."
                )
            print(
                f"SKIP {pkg.full_name}@{pkg.version} path={pkg.path} "
                f"already exists (hash match: {local_webc_sha256})"
            )
            skipped += 1
            continue

        # batch deps publish earlier (dependency order); the rest must already
        # be in the registry or the published webc cannot resolve them
        for dep_name, dep_version in sorted(pkg.dependencies.items()):
            if dep_name in packages:
                continue
            if not get_published_package_version(
                graphql_url, dep_name, dep_version
            ).exists:
                raise SystemExit(
                    f"{pkg.full_name}@{pkg.version} depends on {dep_name}@{dep_version}, "
                    "which is neither published nor part of this run."
                )

        if args.dry_run:
            print(
                f"PUBLISH {pkg.full_name}@{pkg.version} path={pkg.path} (would publish)"
            )
            published += 1
            continue

        print(f"PUBLISH {pkg.full_name}@{pkg.version} path={pkg.path} rev={rev}")
        with tempfile.TemporaryDirectory(prefix="publish-webc-") as tmpdir:
            staged = stage_with_provenance(pkg, rev, tmpdir)
            staged_sha = build_webc_sha256(staged, pkg)
            run(
                [
                    "wasmer",
                    "publish",
                    "--non-interactive",
                    "--registry",
                    publish_registry,
                ],
                cwd=staged,
            )
        verify_published(graphql_url, pkg, staged_sha)
        published += 1

    print(f"Done. published={published} skipped={skipped} total={len(ordered)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
