#!/usr/bin/env python3
# Stand up the wasix overlay cargo registry locally -- the actual deployable
# (the wasm under wasmer, as on Edge), seeded from this repo's fresh mint -- so
# you can resolve and build against your own forks instead of the public
# deployment. The "rather than hoping the external one is up" loop.
#
#   nix run .#scripts.cargo-registry-serve
#   nix run .#scripts.cargo-registry-serve -- --port 8000 --data ./registry-data
#   nix run .#scripts.cargo-registry-serve -- --exec cargo update -p tokio
#
# Rebuilds .#cargoRegistry + the wasix server (so a patch edit is picked up next
# run), runs the server under wasmer, publishes every minted crate through its
# real publish API, applies the mint's shadow limits, then stays foreground with
# the config stanza to paste, or runs a one-off command and tears down. This
# instance has network, so unforked crates pass through to crates.io.
import argparse
import hashlib
import json
import signal
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path

TOKEN = "wasix_local"  # reads never need it; publish/shadow-limit do


def nix_build(*installables):
    out = subprocess.run(
        [
            "nix",
            "build",
            "-L",
            "--accept-flake-config",
            "--no-link",
            "--print-out-paths",
            *installables,
        ],
        check=True,
        stdout=subprocess.PIPE,
        text=True,
    )
    return out.stdout.split()


def wait_ready(base, proc):
    for _ in range(150):
        if proc.poll() is not None:
            raise SystemExit(f"server exited early with {proc.returncode}")
        try:
            urllib.request.urlopen(f"{base}/config.json", timeout=2).read()
            return
        except OSError:
            time.sleep(0.2)
    raise SystemExit("server did not become ready")


def put(base, path, token, body):
    req = urllib.request.Request(
        f"{base}{path}",
        data=json.dumps(body).encode(),
        method="PUT",
        headers={"authorization": token, "content-type": "application/json"},
    )
    urllib.request.urlopen(req).read()


def main():
    ap = argparse.ArgumentParser(description="serve the wasix cargo mint locally")
    ap.add_argument("--port", type=int, default=8000)
    ap.add_argument("--data", help="storage dir (default: a temp dir, wiped on exit)")
    ap.add_argument(
        "--exec",
        nargs=argparse.REMAINDER,
        help="run a command against the registry, then exit",
    )
    args = ap.parse_args()

    base = f"http://127.0.0.1:{args.port}"
    token_hash = hashlib.sha256(TOKEN.encode()).hexdigest()

    print("building .#cargoRegistry and the wasix server ...", file=sys.stderr)
    registry = nix_build(".#cargoRegistry")[0]
    server = nix_build(".#wasmerPackages.wasix-cargo-registry")[0]
    manifest = json.loads((Path(registry) / "manifest.json").read_text())
    wasm = f"{server}/bin/wasix-cargo-registry.wasm"
    publisher = f"{registry}/publish-crate.py"

    tmp = None
    if args.data:
        data = Path(args.data).resolve()
        data.mkdir(parents=True, exist_ok=True)
    else:
        tmp = tempfile.TemporaryDirectory(prefix="wasix-registry-")
        data = Path(tmp.name)

    # --volume (not --mapdir): durable writes need their fsync rights, else
    # publish hangs. 0.0.0.0 inside the guest; reached on loopback.
    proc = subprocess.Popen(
        [
            "wasmer",
            "run",
            wasm,
            "--net",
            "--enable-threads",
            "--volume",
            f"{data}:/data",
            "--env",
            f"REGISTRY_LISTEN_ADDR=0.0.0.0:{args.port}",
            "--env",
            f"REGISTRY_BASE_URL={base}",
            "--env",
            f"REGISTRY_AUTH_TOKEN_HASHES={token_hash}",
            "--env",
            "REGISTRY_STORAGE_PATH=/data",
        ]
    )
    try:
        wait_ready(base, proc)

        for crate in sorted((Path(registry) / "crates").glob("*.crate")):
            subprocess.run(
                [sys.executable, publisher, str(crate), base, TOKEN], check=True
            )
        for limit in manifest["shadowLimits"]:
            put(
                base,
                f"/api/v1/crates/{limit['crate']}/shadow-limit",
                TOKEN,
                {"limit": limit["limit"]},
            )

        print(f"\noverlay registry live at {base}")
        print(
            f"  {len(manifest['crates'])} builds, {len(manifest['shadowLimits'])} shadow limits, storage {data}"
        )
        print("\npoint a project at it with .cargo/config.toml:\n")
        print("  [source.crates-io]")
        print('  replace-with = "wasix"')
        print("  [source.wasix]")
        print(f'  registry = "sparse+{base}/"\n')

        if args.exec:
            sys.exit(subprocess.run(args.exec).returncode)

        print("Ctrl-C to stop.")
        signal.signal(signal.SIGINT, lambda *_: sys.exit(0))
        proc.wait()
    finally:
        proc.send_signal(signal.SIGTERM)
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
        if tmp:
            tmp.cleanup()


if __name__ == "__main__":
    main()
