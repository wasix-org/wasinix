#!/usr/bin/env bash
# Provision-or-fetch the index volume's S3 credentials, then publish the built
# registry. Run via `nix run .#scripts.publish`, which provides the patched
# wasmer, rclone, and python3. Env: WASMER_APP, INDEX_VOLUME (+ WASMER_TOKEN for
# auth). Args: --registry <path> [--rev <sha>].
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

# the rclone remote name `wasmer app volume credentials` emits
remote="edge-${WASMER_APP#*/}"
block=$(mktemp)
mkdir -p ~/.config/rclone
# the credentials read path works once provisioned; the first run has none, so
# provision with the patched rotate-secrets (per AppVolume) and read again.
# rotate prints the creds on stdout, so discard it and re-read into a file to
# keep them out of the log.
if ! wasmer app volume credentials "$WASMER_APP" --registry wasmer.io --format rclone >"$block" 2>/dev/null; then
  wasmer app volume rotate-secrets "$WASMER_APP" --volume "$INDEX_VOLUME" --registry wasmer.io >/dev/null
  wasmer app volume credentials "$WASMER_APP" --registry wasmer.io --format rclone >"$block"
fi
cat "$block" >>~/.config/rclone/rclone.conf

python3 pkgs/python-registry/publish.py \
  --registry "$registry" \
  --remote "$remote:$INDEX_VOLUME" \
  --rev "$rev"
