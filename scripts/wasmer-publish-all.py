#!/usr/bin/env python3

# Build every shipped Wasmer (webc) package and publish those the registry
# does not already have. Packages publish in name order; the only
# cross-package webc [dependencies] edge (git -> bash) is satisfied by it.

import argparse
import hashlib
import json
import subprocess
import sys
import tempfile
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


@dataclass(frozen=True)
class PublishedPackageVersion:
    exists: bool
    webc_sha256: str | None


def run(cmd: list[str], *, cwd: Path | None = None, capture_output: bool = False) -> subprocess.CompletedProcess[str]:
    print(f"+ {' '.join(cmd)}")
    return subprocess.run(
        cmd,
        cwd=str(cwd) if cwd else None,
        check=True,
        text=True,
        capture_output=capture_output,
    )


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


def read_packages(pkg_root: Path) -> dict[str, Package]:
    if not pkg_root.is_dir():
        raise SystemExit(f"Package directory does not exist: {pkg_root}")

    packages: dict[str, Package] = {}
    for toml_path in pkg_root.glob("**/wasmer.toml"):
        pkg_dir = toml_path.parent
        with toml_path.open("rb") as f:
            data = tomllib.load(f)

        package = data.get("package", {})
        full_name = package.get("name")
        version = package.get("version")
        if not isinstance(full_name, str) or not isinstance(version, str):
            raise SystemExit(f"Missing/invalid package.name or package.version in {toml_path}")

        if full_name in packages:
            raise SystemExit(f"Duplicate package name {full_name} in {toml_path} and {packages[full_name].path / 'wasmer.toml'}")

        packages[full_name] = Package(
            full_name=full_name,
            version=version,
            path=pkg_dir,
        )

    if not packages:
        raise SystemExit(f"No packages found under {pkg_root}")

    return packages


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


def build_local_webc_sha256(pkg: Package) -> str:
    with tempfile.TemporaryDirectory(prefix="wasmer-publish-all-") as tmpdir:
        out = Path(tmpdir) / "package.webc"
        run(["wasmer", "package", "build", "--quiet", "--out", str(out), "."], cwd=pkg.path)
        if not out.is_file():
            raise SystemExit(f"Expected local .webc output missing for {pkg.full_name}@{pkg.version}: {out}")
        return sha256_file(out)


def get_published_package_version(graphql_url: str, full_name: str, version: str) -> PublishedPackageVersion:
    payload = {
        "query": (
            "query GetPackageVersion($name: String!, $version: String!) { "
            "getPackageVersion(name: $name, version: $version) { "
            "id "
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
        raise SystemExit(f"GraphQL request failed ({exc.code}) for {full_name}@{version}: {exc.reason}") from exc
    except error.URLError as exc:
        raise SystemExit(f"GraphQL request failed for {full_name}@{version}: {exc.reason}") from exc

    try:
        doc = json.loads(body)
    except json.JSONDecodeError as exc:
        raise SystemExit(f"Invalid GraphQL JSON response for {full_name}@{version}: {exc}") from exc

    if "errors" in doc and doc["errors"]:
        raise SystemExit(f"GraphQL returned errors for {full_name}@{version}: {doc['errors']}")

    data = doc.get("data")
    if not isinstance(data, dict):
        raise SystemExit(f"GraphQL response missing data for {full_name}@{version}: {doc}")

    package_version = data.get("getPackageVersion")
    if package_version is None:
        return PublishedPackageVersion(exists=False, webc_sha256=None)
    if not isinstance(package_version, dict):
        raise SystemExit(f"GraphQL getPackageVersion has unexpected shape for {full_name}@{version}: {package_version}")

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

    return PublishedPackageVersion(exists=True, webc_sha256=webc_sha256)


def main() -> int:
    parser = argparse.ArgumentParser(description="Build and publish all Wasmer packages from result/pkg.")
    parser.add_argument(
        "--registry",
        required=True,
        help="Wasmer registry host or URL (e.g. wasmer.io or https://wasmer.io).",
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
    args = parser.parse_args()

    repo_root = Path(__file__).resolve().parents[1]
    pkg_root = repo_root / "result" / "pkg"

    run(["nix", "build", ".#legacyPackages.x86_64-linux.allWasmerPackages"], cwd=repo_root)

    packages = read_packages(pkg_root)
    ordered = [packages[name] for name in sorted(packages)]

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
        published_info = get_published_package_version(graphql_url, pkg.full_name, pkg.version)
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
            local_webc_sha256 = build_local_webc_sha256(pkg)
            if local_webc_sha256 != published_info.webc_sha256:
                raise SystemExit(
                    f"Hash mismatch for existing package {pkg.full_name}@{pkg.version}: "
                    f"local={local_webc_sha256} registry={published_info.webc_sha256}"
                )
            print(
                f"SKIP {pkg.full_name}@{pkg.version} path={pkg.path} "
                f"already exists (hash match: {local_webc_sha256})"
            )
            skipped += 1
            continue

        if args.dry_run:
            print(f"PUBLISH {pkg.full_name}@{pkg.version} path={pkg.path} (would publish)")
            published += 1
            continue

        print(f"PUBLISH {pkg.full_name}@{pkg.version} path={pkg.path}")
        run(["wasmer", "publish", "--non-interactive", "--registry", publish_registry], cwd=pkg.path)
        published += 1

    print(f"Done. published={published} skipped={skipped} total={len(ordered)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
