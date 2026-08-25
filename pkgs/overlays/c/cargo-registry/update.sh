#!/usr/bin/env bash
# Update cargo-registry's untagged source, derived lockfile, and cargoHash.
#
# The source has no tags, so the pin follows main's head commit; the lockfile is
# derived from upstream's rather than resolved here. Invoked as
# `update.sh <nix-update ...>` by the driver.
set -euo pipefail

package="$(git rev-parse --show-toplevel)/pkgs/overlays/c/cargo-registry"
nix_file="$package/package.nix"

# The pin block: rev and hash belong to the same fetchFromGitHub, so both are
# read and rewritten inside it rather than by first-match in the file.
block='/repo = "cargo-registry"/,/hash = "sha256-/'
current=$(sed -n "$block"'s/.*rev = "\([0-9a-f]\{40\}\)".*/\1/p' "$nix_file" | head -1)
if [ -z "$current" ]; then
  echo "cargo-registry source pin block not found" >&2
  exit 1
fi

request=$(wasinix update request)
if [ "$(jq -r '.mode // ""' <<<"$request")" = revision ]; then
  read -r kind owner repo rev < <(jq -r '[.source.kind, .source.owner, .source.repo, .source.rev] | @tsv' <<<"$request")
  if [ "$kind" != github ] || [ "$owner/$repo" != wasix-org/cargo-registry ]; then
    echo "cargo-registry revision source must be GitHub wasix-org/cargo-registry" >&2
    exit 1
  fi
else
  rev=$(curl -fsSL -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/wasix-org/cargo-registry/commits/main" | jq -r .sha)
fi

changed="already at"
if [ "$rev" != "$current" ]; then
  source_hash=$(nix store prefetch-file --json --unpack \
    "https://github.com/wasix-org/cargo-registry/archive/$rev.tar.gz" | jq -r .hash)
  old_hash=$(sed -n "$block"'s/.*hash = "\(sha256-[^"]*\)".*/\1/p' "$nix_file" | head -1)
  sed -i -e "$block"'s|rev = "'"$current"'"|rev = "'"$rev"'"|' \
    -e "$block"'s|hash = "'"$old_hash"'"|hash = "'"$source_hash"'"|' \
    "$nix_file"
  changed="updated to"
fi

curl -fsSL "https://raw.githubusercontent.com/wasix-org/cargo-registry/$rev/Cargo.lock" |
  python3 "$package/derive-lock.py" /dev/stdin >"$package/Cargo.lock"

# --version=skip: the pin is a commit, so there is no release for nix-update to
# find; it is here only to re-derive cargoHash.
WASINIX_UPDATE_REQUEST= wasinix update nix-update -- "$@" --version=skip

echo "source $changed $rev"
