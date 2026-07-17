#!/usr/bin/env bash
# Build every CI package independently, emitting a JUnit report (one test case
# per package). With a signing key present, each package is signed and uploaded
# to the cache as it builds (--copy-to), so a timeout or cancel never loses
# built work. Without a key (e.g. fork PRs) it just builds.

set -uo pipefail # no -e: keep building past failures

ENDPOINT="https://1541b1e8a3fc6ad155ce67ef38899700.r2.cloudflarestorage.com"
CACHE_STORE="s3://wasinix-cache?region=auto&endpoint=$ENDPOINT&compression=zstd"
CACHE_PUB_KEY="wasinix-1:jvsqbOJGsZxMvg97fuyNCWCc+t2nn6uHB47kQCGNmXI="

CI_ATTR="${CI_ATTR:-.#legacyPackages.$(nix eval --raw --impure --expr 'builtins.currentSystem').ci}"
RESULT_FILE="${RESULT_FILE:-nix-fast-build-result.xml}"

COPY_ARGS=()
if [ -n "${NIX_SIGNING_KEY:-}" ]; then
  KEY_FILE=$(mktemp)
  chmod 600 "$KEY_FILE"
  trap 'rm -f "$KEY_FILE"' EXIT
  printf '%s\n' "$NIX_SIGNING_KEY" >"$KEY_FILE"
  pub=$(nix key convert-secret-to-public <"$KEY_FILE")
  if [ "$pub" != "$CACHE_PUB_KEY" ]; then
    echo "ERROR: NIX_SIGNING_KEY does not match CACHE_PUB_KEY ($pub)" >&2
    exit 1
  fi
  COPY_ARGS=(--copy-to "$CACHE_STORE&secret-key=$KEY_FILE")
  echo "Incremental cache upload enabled."
else
  echo "No signing key; building without cache upload."
fi

# --copy-to pushes only runtime closures, so build-only deps never reach the
# cache. Capture the needed builds before building (afterwards they would read
# "local", not "notBuilt"); they are pushed after the build. JOBS_FILE reuses
# the eval from the rebuild-diff step (scripts/eval-diff.py) instead of
# evaling a second time.
PUSH_DRVS=""
if [ -n "${NIX_SIGNING_KEY:-}" ]; then
  if [ -n "${JOBS_FILE:-}" ] && [ -s "$JOBS_FILE" ]; then
    PUSH_DRVS=$(jq -r '.neededBuilds[]?' "$JOBS_FILE" | sort -u)
  else
    PUSH_DRVS=$(
      nix-eval-jobs \
        --flake "$CI_ATTR" --check-cache-status --workers "$(nproc)" \
        --option accept-flake-config true 2>/dev/null |
        jq -r '.neededBuilds[]?' | sort -u
    )
  fi
fi

echo "Building all packages under $CI_ATTR independently..."

# --skip-cached: on a warm cache only changed packages rebuild.
nix-fast-build \
  --flake "$CI_ATTR" \
  --skip-cached \
  --retries 3 \
  --no-nom \
  --no-link \
  --result-file "$RESULT_FILE" \
  --result-format junit \
  --option accept-flake-config true \
  "${COPY_ARGS[@]}"
status=$?

# Realise and push the captured build-only deps: nix-fast-build substitutes
# cached outputs, so these may never have been realised on the runner.
# --keep-going so one broken dep does not block the rest; nix copy skips
# already-cached paths, so this is a no-op once warm.
if [ -n "${NIX_SIGNING_KEY:-}" ] && [ -n "$PUSH_DRVS" ]; then
  # shellcheck disable=SC2086
  outs=$(printf '%s\n' "$PUSH_DRVS" | xargs -r nix-store --realise --keep-going 2>/dev/null)
  if [ -n "$outs" ]; then
    echo "Pushing $(printf '%s\n' "$outs" | wc -l) build-time paths --copy-to misses..."
    # shellcheck disable=SC2086
    nix copy --to "$CACHE_STORE&secret-key=$KEY_FILE" $outs ||
      echo "WARN: build-dep push failed (non-fatal)." >&2
  fi
fi

exit "$status"
