#!/usr/bin/env bash
# Bump ddtrace, then re-derive the pin that follows from it.
#
# ddtrace bundles libddwaf's .so (no wasm release to download), so our libddwaf
# must be exactly the LIBDDWAF_VERSION the new setup.py expects. That version is
# ddtrace's to dictate, so libddwaf carries no updateScript of its own and is
# bumped from here.
#
# Invoked as `update.sh <nix-update ...>`: the driver passes the command
# nix-update-script produced, so the package declares its bump once.
set -euo pipefail

repo=$(git rev-parse --show-toplevel)
ddtrace="$repo/pkgs/overlay/python-packages/ddtrace/package.nix"
libddwaf="$repo/pkgs/overlay/packages/libddwaf/package.nix"

wasinix update nix-update -- "$@"

version=$(sed -n '0,/version = "/s/.*version = "\([^"]*\)".*/\1/p' "$ddtrace")
request=$(wasinix update request)
ref="v$version"
if [ "$(jq -r '.mode // ""' <<<"$request")" = revision ]; then
  read -r kind owner srcrepo ref < <(jq -r '[.source.kind, .source.owner, .source.repo, .source.rev] | @tsv' <<<"$request")
  if [ "$kind" != github ] || [ "$owner/$srcrepo" != DataDog/dd-trace-py ]; then
    echo "ddtrace revision source must be GitHub DataDog/dd-trace-py" >&2
    exit 1
  fi
fi
setup=$(curl -fsSL "https://raw.githubusercontent.com/DataDog/dd-trace-py/$ref/setup.py")
want=$(sed -n 's/^LIBDDWAF_VERSION[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' <<<"$setup" | head -1)
if [ -z "$want" ]; then
  echo "LIBDDWAF_VERSION not found in dd-trace-py $ref setup.py;" \
    "upstream moved it, so the libddwaf pairing needs re-deriving by hand" >&2
  exit 1
fi

current=$(sed -n '0,/version = "/s/.*version = "\([^"]*\)".*/\1/p' "$libddwaf")
if [ "$current" = "$want" ]; then
  echo "libddwaf pin ok"
  exit 0
fi

# libddwaf tags are the bare version (tag = finalAttrs.version)
new_hash=$(nix store prefetch-file --json --unpack \
  "https://github.com/DataDog/libddwaf/archive/$want.tar.gz" | jq -r .hash)
old_hash=$(sed -n '0,/hash = "sha256-/s/.*hash = "\(sha256-[^"]*\)".*/\1/p' "$libddwaf")
sed -i \
  -e "s|version = \"$current\"|version = \"$want\"|" \
  -e "s|hash = \"$old_hash\"|hash = \"$new_hash\"|" \
  "$libddwaf"
grep -qF "version = \"$want\"" "$libddwaf" || {
  echo "libddwaf version rewrite failed" >&2
  exit 1
}
grep -qF "hash = \"$new_hash\"" "$libddwaf" || {
  echo "libddwaf hash rewrite failed" >&2
  exit 1
}

# No " -> ": the driver scans stdout backwards for an outcome line and must land
# on nix-update's, not this one.
echo "libddwaf bumped $current to $want"
