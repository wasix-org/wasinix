#!/usr/bin/env bash
# Build every CI package independently, emitting a JUnit report (one test case
# per package). Needs no secrets, so it runs on forks; pushing is separate
# (ci-push.sh). A down/unreachable cache only slows builds (Nix falls back to
# source). Exits non-zero on any failure but always writes the report.

set -uo pipefail # no -e: keep building past failures

CI_ATTR="${CI_ATTR:-.#legacyPackages.$(nix eval --raw --impure --expr 'builtins.currentSystem').ci}"
RESULT_FILE="${RESULT_FILE:-nix-fast-build-result.xml}"

echo "Building all packages under $CI_ATTR independently..."

# --skip-cached: on a warm cache only changed packages rebuild.
exec nix run nixpkgs#nix-fast-build -- \
  --flake "$CI_ATTR" \
  --skip-cached \
  --no-nom \
  --no-link \
  --result-file "$RESULT_FILE" \
  --result-format junit \
  --option accept-flake-config true
