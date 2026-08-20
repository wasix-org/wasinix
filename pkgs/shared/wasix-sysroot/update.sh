#!/usr/bin/env bash
# Bump wasix-libc, then re-derive the witx pins that follow from it.
#
# The sysroot's witx headers are submodules of wasix-libc, so which revision of
# each we fetch is dictated by the libc revision we pinned. That is package
# knowledge, so it lives next to the pin it edits.
#
# Invoked as `update.sh <nix-update ...>` by the driver.
set -euo pipefail

libc="$(git rev-parse --show-toplevel)/pkgs/shared/wasix-sysroot/libc.nix"
# The wasix-libc pin: tag or rev, plus the hash belonging to the same fetcher.
source_block='/repo = "wasix-libc"/,/hash = "sha256-/'

source_revision() {
  local pin
  pin=$(sed -n "$source_block"'s/.*\(tag\|rev\) = "\([^"]*\)".*/\2/p' "$libc" | head -1)
  if [ -z "$pin" ]; then
    echo "wasix-libc source pin block not found in libc.nix" >&2
    exit 1
  fi
  # The literal nix interpolation, not a shell one: the pin follows version.
  # shellcheck disable=SC2016
  if [ "$pin" = 'v${version}' ]; then
    printf 'v%s\n' "$(sed -n '0,/version = "/s/.*version = "\([^"]*\)".*/\1/p' "$libc")"
  else
    printf '%s\n' "$pin"
  fi
}

request=$(wasinix update request --expect wasix-libc)
mode=$(jq -r '.mode // ""' <<<"$request")

if [ "$mode" = revision ]; then
  read -r kind owner srcrepo want < <(jq -r '[.source.kind, .source.owner, .source.repo, .source.rev] | @tsv' <<<"$request")
  if [ "$kind" != github ] || [ "$owner/$srcrepo" != wasix-org/wasix-libc ]; then
    echo "wasix-libc revision source must be a GitHub wasix-org/wasix-libc" >&2
    exit 1
  fi
fi
wasinix update nix-update -- "$@"
rev=$(source_revision)
if [ "$mode" = revision ] && [ "$rev" != "$want" ]; then
  echo "wasix-libc resolved requested revision $want to $rev" >&2
  exit 1
fi

# Each witx pin is the submodule's commit inside wasix-libc at that revision.
bumped=()
sync() {
  local sub=$1 owner=$2 repo=$3 block sha current old_hash new_hash
  sha=$(curl -fsSL -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/wasix-org/wasix-libc/contents/$sub?ref=$rev" | jq -r .sha)
  block="/repo = \"$repo\"/,/hash = \"/"
  current=$(sed -n "$block"'s/.*rev = "\([^"]*\)".*/\1/p' "$libc" | head -1)
  if [ -z "$current" ]; then
    echo "$repo: witx pin block not found in libc.nix" >&2
    exit 1
  fi
  [ "$current" = "$sha" ] && return 0
  old_hash=$(sed -n "$block"'s/.*hash = "\([^"]*\)".*/\1/p' "$libc" | head -1)
  new_hash=$(nix store prefetch-file --json --unpack \
    "https://github.com/$owner/$repo/archive/$sha.tar.gz" | jq -r .hash)
  sed -i -e "$block"'s|rev = "'"$current"'"|rev = "'"$sha"'"|' \
    -e "$block"'s|hash = "'"$old_hash"'"|hash = "'"$new_hash"'"|' \
    "$libc"
  bumped+=("$repo ${sha:0:12}")
}

sync tools/wasi-headers/WASI WebAssembly WASI
sync tools/wasix-headers/WASI wasix-org wasix-witx

# No " -> ": the driver scans stdout backwards for an outcome line and must land
# on the bump's, not this one.
if [ ${#bumped[@]} -gt 0 ]; then
  echo "witx pins synced: $(
    IFS=,
    echo "${bumped[*]}"
  )"
else
  echo "witx pins ok"
fi
