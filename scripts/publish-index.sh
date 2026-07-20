#!/usr/bin/env bash
# Provision-or-fetch the index volume's S3 credentials, then publish the built
# registry. Run via `nix run .#scripts.publish-index`, which provides the patched
# wasmer, rclone, and python3. The app is identified by pkgs/python-registry/
# app.yaml (its app_id), so no app name is needed. Env: INDEX_VOLUME,
# WASMER_REGISTRY (which wasmer registry to talk to, default wasmer.io), +
# WASMER_TOKEN for auth. Args: --registry <path> [--rev <sha>].
set -euo pipefail

registry="" rev=""
while [ $# -gt 0 ]; do
  case "$1" in
  --registry)
    registry="$2"
    shift 2
    ;;
  --rev)
    rev="$2"
    shift 2
    ;;
  *)
    echo "unknown arg: $1" >&2
    exit 1
    ;;
  esac
done
[ -n "$registry" ] || {
  echo "--registry required" >&2
  exit 1
}

# which wasmer registry to fetch the volume's S3 creds from (wasmer.io = prod,
# wasmer.wtf = dev)
wasmer_registry="${WASMER_REGISTRY:-wasmer.io}"

block=$(mktemp)
mkdir -p ~/.config/rclone
# Run the volume commands from the app.yaml directory; with no app argument the
# CLI resolves the app from that config's app_id, which avoids depending on a
# name resolving on the selected registry.
# The credentials read path works once provisioned; the first run has none, so
# provision with the patched rotate-secrets (per AppVolume) and read again.
# rotate prints the creds on stdout, so discard it and re-read into a file to
# keep them out of the log.
app_dir="pkgs/python-registry"
volume_creds() {
  (cd "$app_dir" && wasmer app volume credentials --registry "$wasmer_registry" --format rclone)
}
if ! volume_creds >"$block" 2>/dev/null; then
  (cd "$app_dir" && wasmer app volume rotate-secrets --volume "$INDEX_VOLUME" --registry "$wasmer_registry") >/dev/null
  volume_creds >"$block"
fi
cat "$block" >>~/.config/rclone/rclone.conf

# the section name the credentials snippet defines (edge-<app>-<volume>); parse
# it rather than reconstruct, since the CLI mangles the volume into it.
remote=$(sed -n 's/^\[\(.*\)\]$/\1/p' "$block" | head -1)
[ -n "$remote" ] || {
  echo "no rclone remote section in the credentials output" >&2
  exit 1
}

# The volume's S3 bucket is a per-deploy id, so discover it.
# The endpoint hosts exactly one bucket, so just pick that one.
bucket=$(rclone --quiet lsd "$remote:" | awk '{print $NF}' | head -1)
[ -n "$bucket" ] || {
  echo "could not list the volume's S3 bucket" >&2
  exit 1
}

python3 pkgs/python-registry/publish.py \
  --registry "$registry" \
  --remote "$remote:$bucket" \
  --rev "$rev"
