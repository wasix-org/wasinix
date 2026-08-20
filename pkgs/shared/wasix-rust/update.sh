#!/usr/bin/env bash
# Bump the wasix rust fork, then re-derive the pin that follows from it.
#
# The stage0 bootstrap pin follows from the new fork source: its version, url and
# hash are dictated by the fork's own src/stage0. That is package knowledge, so
# it lives next to the pin it edits. The cargo vendor hash follows too, but
# nix-update re-derives that one itself off passthru.cargoDeps.
#
# Invoked as `update.sh <nix-update ...>`: the driver passes the command
# nix-update-script produced, so the package declares its bump once.
set -euo pipefail

toolchain="$(git rev-parse --show-toplevel)/pkgs/shared/wasix-rust/package.nix"

wasinix update nix-update -- "$@"

version=$(sed -n '0,/version = "/s/.*version = "\([^"]*\)".*/\1/p' "$toolchain")
request=$(wasinix update request)
ref="v$version"
if [ "$(jq -r '.mode // ""' <<<"$request")" = revision ]; then
  read -r kind owner srcrepo ref < <(jq -r '[.source.kind, .source.owner, .source.repo, .source.rev] | @tsv' <<<"$request")
  if [ "$kind" != github ] || [ "$owner/$srcrepo" != wasix-org/rust ]; then
    echo "rust revision source must be GitHub wasix-org/rust" >&2
    exit 1
  fi
fi
stage0=$(curl -fsSL "https://raw.githubusercontent.com/wasix-org/rust/$ref/src/stage0")
field() { sed -n "s/^$1=//p" <<<"$stage0" | head -1; }
date=$(field compiler_date)
ver=$(field compiler_version)
server=$(field dist_server)

bootstrap='/pname = "rust-bootstrap"/,/^  }/'
current=$(sed -n "$bootstrap"'s/.*version = "\([^"]*\)".*/\1/p' "$toolchain" | head -1)
if [ "$current" = "$ver" ]; then
  echo "stage0 bootstrap ok"
  exit 0
fi

new_hash=$(nix store prefetch-file --json \
  "$server/dist/$date/rust-$ver-x86_64-unknown-linux-gnu.tar.xz" | jq -r .hash)
old_hash=$(sed -n "$bootstrap"'s/.*\(sha256-[A-Za-z0-9+\/=]*\).*/\1/p' "$toolchain" | head -1)

# buildTriple stays a nix interpolation, so the url is written literally; the
# prefetch above resolves it to the same x86_64-unknown-linux-gnu tarball.
url="$server/dist/$date/rust-$ver-\${buildTriple}.tar.xz"
sed -i \
  -e "$bootstrap"'s|version = "[^"]*"|version = "'"$ver"'"|' \
  -e "$bootstrap"'s|url = "[^"]*rust-[^"]*\.tar\.xz"|url = "'"$url"'"|' \
  -e "$bootstrap"'s|hash = "'"$old_hash"'"|hash = "'"$new_hash"'"|' \
  "$toolchain"
grep -qF "version = \"$ver\"" "$toolchain" || {
  echo "stage0 version rewrite failed" >&2
  exit 1
}
grep -qF "hash = \"$new_hash\"" "$toolchain" || {
  echo "stage0 hash rewrite failed" >&2
  exit 1
}

# No " -> ": the driver scans stdout backwards for an outcome line and must land
# on nix-update's, not this one.
echo "stage0 bootstrap synced to $ver ($date)"
