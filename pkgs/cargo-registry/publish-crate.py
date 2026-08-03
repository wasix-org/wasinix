#!/usr/bin/env python3
"""Publish a minted .crate to a running overlay registry via its publish API.

`cargo publish` insists on refreshing the crates.io index to check a crate's
own dependencies before uploading, so it cannot run offline (or against a
crate whose deps aren't on crates.io yet). This speaks the publish wire format
directly instead: it derives cargo's publish metadata from the crate's own
normalized Cargo.toml and PUTs `<len><json><len><tarball>`. The server derives
the sparse-index entry from that (src/publish.rs `to_index_entry`), including
the checksum, so nothing here contacts crates.io.

The publish API lives at the overlay root (`/api/v1/crates/new`); the `/publish/`
prefix is only a second index view, whose config.json points `api` back here.

    publish-crate.py <crate.crate> <base-url> <token>
"""

import struct
import sys
import tarfile
import tomllib
import urllib.request


def deps_from_manifest(manifest):
    """cargo's publish `deps` array, flattened from every dependency table."""
    kinds = {
        "dependencies": "normal",
        "dev-dependencies": "dev",
        "build-dependencies": "build",
    }
    out = []

    def emit(table, kind, target):
        for key, spec in table.items():
            # cargo normalizes every dep to an inline table; a bare string
            # version is still valid TOML input, so accept both.
            if isinstance(spec, str):
                spec = {"version": spec}
            name, explicit = key, None
            if "package" in spec:
                name, explicit = spec["package"], key
            dep = {
                "name": name,
                "version_req": spec.get("version", "*"),
                "features": spec.get("features", []),
                "optional": spec.get("optional", False),
                "default_features": spec.get("default-features", True),
                "target": target,
                "kind": kind,
            }
            if explicit is not None:
                dep["explicit_name_in_toml"] = explicit
            if "registry" in spec:
                dep["registry"] = spec["registry"]
            out.append(dep)

    for table_name, kind in kinds.items():
        emit(manifest.get(table_name, {}), kind, None)
    for cfg, tables in manifest.get("target", {}).items():
        for table_name, kind in kinds.items():
            emit(tables.get(table_name, {}), kind, cfg)
    return out


def metadata_from_manifest(manifest):
    pkg = manifest["package"]
    return {
        "name": pkg["name"],
        "vers": pkg["version"],
        "deps": deps_from_manifest(manifest),
        "features": manifest.get("features", {}),
        "links": pkg.get("links"),
        "rust_version": pkg.get("rust-version"),
    }


def read_manifest(crate_path):
    with tarfile.open(crate_path, "r:gz") as tar:
        root = tar.getnames()[0].split("/", 1)[0]
        member = tar.extractfile(f"{root}/Cargo.toml")
        if member is None:
            raise SystemExit(f"publish-crate: {crate_path} has no {root}/Cargo.toml")
        return tomllib.loads(member.read().decode())


def main():
    if len(sys.argv) != 4:
        raise SystemExit(__doc__)
    crate_path, base_url, token = sys.argv[1:4]

    manifest = read_manifest(crate_path)
    import json

    meta = json.dumps(metadata_from_manifest(manifest)).encode()
    with open(crate_path, "rb") as fh:
        tarball = fh.read()

    body = (
        struct.pack("<I", len(meta)) + meta + struct.pack("<I", len(tarball)) + tarball
    )

    url = f"{base_url.rstrip('/')}/api/v1/crates/new"
    req = urllib.request.Request(
        url, data=body, method="PUT", headers={"Authorization": token}
    )
    try:
        with urllib.request.urlopen(req) as resp:
            print(
                f"published {manifest['package']['name']} {manifest['package']['version']} -> {resp.status}"
            )
    except urllib.error.HTTPError as err:
        detail = err.read().decode(errors="replace")
        raise SystemExit(
            f"publish-crate: {manifest['package']['name']} {manifest['package']['version']} rejected: {err.code} {detail}"
        )


if __name__ == "__main__":
    main()
