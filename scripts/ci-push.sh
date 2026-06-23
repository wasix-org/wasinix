#!/usr/bin/env bash
# Sign and push locally-built packages to the S3/R2 cache. Independent of
# ci-build.sh: it asks Nix which outputs exist locally but aren't cached yet
# and pushes exactly those, so it's robust to partial builds and to retrying an
# earlier failed push.
#
# Requires: NIX_SIGNING_KEY, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY

set -euxo pipefail

for var in NIX_SIGNING_KEY AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY; do
  if [ -z "${!var:-}" ]; then
    echo "ERROR: Required environment variable $var is not set." >&2
    exit 1
  fi
done

BUCKET="wasinix-cache"
ENDPOINT="https://1541b1e8a3fc6ad155ce67ef38899700.r2.cloudflarestorage.com"
PUBLIC_URL="https://nix-cache.wasix.org"
CACHE_PUB_KEY="wasinix-1:jvsqbOJGsZxMvg97fuyNCWCc+t2nn6uHB47kQCGNmXI="
CACHE_STORE="s3://$BUCKET?region=auto&endpoint=$ENDPOINT&compression=zstd"

SYSTEM=$(nix eval --raw --impure --accept-flake-config --expr 'builtins.currentSystem')
CI_ATTR="${CI_ATTR:-.#legacyPackages.$SYSTEM.ci}"

# Find every output that exists locally but is not yet in the cache.
# cacheStatus != "cached" means not in our cache; keep those built locally.
echo "Evaluating $CI_ATTR to find paths missing from the cache..."
PATHS=$(nix run nixpkgs#nix-eval-jobs -- \
  --flake "$CI_ATTR" \
  --check-cache-status \
  --option extra-substituters "$PUBLIC_URL" \
  --option extra-trusted-public-keys "$CACHE_PUB_KEY" 2>/dev/null |
  jq -r 'select(.cacheStatus != "cached") | .outputs[]' |
  while read -r p; do
    # only outputs actually present in the local store
    if [ -n "$p" ] && nix path-info "$p" >/dev/null 2>&1; then echo "$p"; fi
  done | sort -u)

if [ -z "$PATHS" ]; then
  echo "Nothing new to push — cache is already up to date."
  exit 0
fi

echo "Paths to push:"
echo "$PATHS"

SIGNING_KEY_FILE=$(mktemp)
trap 'rm -f "$SIGNING_KEY_FILE"' EXIT
echo "$NIX_SIGNING_KEY" >"$SIGNING_KEY_FILE"
chmod 600 "$SIGNING_KEY_FILE"

ACTUAL_PUB_KEY=$(nix key convert-secret-to-public <"$SIGNING_KEY_FILE")
if [ "$ACTUAL_PUB_KEY" != "$CACHE_PUB_KEY" ]; then
  echo "ERROR: NIX_SIGNING_KEY does not match CACHE_PUB_KEY." >&2
  echo "Expected: $CACHE_PUB_KEY" >&2
  echo "Actual:   $ACTUAL_PUB_KEY" >&2
  exit 1
fi

# sign the full closure (-r) so dependencies are trusted by clients too
echo "Signing paths (recursively)..."
# shellcheck disable=SC2086
nix store sign --recursive --key-file "$SIGNING_KEY_FILE" $PATHS

echo "Pushing to $PUBLIC_URL..."
# shellcheck disable=SC2086
nix copy --to "$CACHE_STORE&secret-key=$SIGNING_KEY_FILE" $PATHS

echo "Successfully pushed all packages to cache."
