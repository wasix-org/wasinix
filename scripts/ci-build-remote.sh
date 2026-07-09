#!/usr/bin/env bash
# Build the CI set from the *local* (possibly dirty) checkout on a remote
# builder box, optionally signing and pushing to the wasinix cache from
# there. A later CI run then finds everything already cached (--skip-cached)
# instead of redoing the work.
#
# Only the wasinix tree itself travels to the remote (<1 MiB); flake inputs
# (nixpkgs, wasmer, ...) are fetched by the remote directly per flake.lock,
# and build outputs go remote -> cache directly. Untracked files are
# invisible to flakes: git add them first or they won't be part of the build.
#
# The remote needs nix (with this user trusted). Pushing additionally needs
# a doppler CLI on the remote authenticated for nix-builder/prd. No wasinix
# checkout is required there.

set -euo pipefail

usage() {
  cat >&2 <<USAGE
usage: $0 [options] [ssh-host]
  ssh-host and -i default to the local .remote-builder config (see
  .remote-builder.example / scripts/remote-builder.sh).
  --no-push            build only, skip the cache upload (no doppler needed)
  -i, --ssh-key FILE   ssh identity file for the remote
  -a, --attr ATTR      flake attribute to build
                       (default: legacyPackages.<remote system>.ci)
  -r, --result-file F  copy the JUnit result file back to this local path
USAGE
  exit 64
}

push=1 ssh_key="" attr="" local_result="" remote=""
while [ $# -gt 0 ]; do
  case "$1" in
  --no-push) push=0 ;;
  -i | --ssh-key)
    ssh_key="${2:?missing argument for $1}"
    shift
    ;;
  -a | --attr)
    attr="${2:?missing argument for $1}"
    shift
    ;;
  -r | --result-file)
    local_result="${2:?missing argument for $1}"
    shift
    ;;
  -h | --help) usage ;;
  -*) usage ;;
  *)
    [ -z "$remote" ] || usage
    remote="$1"
    ;;
  esac
  shift
done
# Fall back to the local .remote-builder config for host and key.
resolver="$(dirname "$0")/remote-builder.sh"
if [ -z "$remote" ]; then
  remote=$("$resolver" host) || exit $?
fi
if [ -z "$ssh_key" ]; then
  ssh_key=$("$resolver" key 2>/dev/null || true)
fi
case "$remote" in
/* | ./* | *.drv)
  echo "error: the positional argument is the ssh host, got a path: $remote" >&2
  echo "hint: pick what to build with -a/--attr <flake attribute>;" >&2
  echo "      store/.drv paths can't be built remotely (the remote re-evaluates" >&2
  echo "      the archived flake source, your local store never travels there)" >&2
  exit 64
  ;;
esac

ssh_opts=()
if [ -n "$ssh_key" ]; then
  ssh_opts=(-i "$ssh_key")
  export NIX_SSHOPTS="-i $ssh_key" # nix flake archive's ssh invocation
fi

if [ -z "$attr" ]; then
  # Deliberately expanded on the remote (unquoted heredoc below): the
  # attribute must match the *builder's* system, not ours.
  # shellcheck disable=SC2016
  attr='legacyPackages.$(nix eval --raw --impure --expr builtins.currentSystem).ci'
fi

runner=""
if [ "$push" -eq 1 ]; then
  runner="doppler run -p nix-builder -c prd --"
fi

# nix flake metadata (unlike archive) copies only the flake's own tree into
# the store, not the input closure; the remote fetches inputs itself, which
# beats pushing ~750 MiB of nixpkgs+wasmer sources through a home uplink.
src=$(nix flake metadata --json | jq -r .path)
echo "Copying flake source ($src) to $remote..."
nix copy --to "ssh://$remote" "$src"

# Unique per run so parallel invocations on the same box don't collide.
remote_result="/tmp/nix-fast-build-$(date +%s%N)-$$.xml"

echo "Source at $src; building remotely..."
# Unquoted heredoc: $src/$attr/$runner/$remote_result expand here; the
# builder only expands the $(...) inside attr. bash -l so nix/doppler
# installed via nix profile are on PATH.
status=0
# shellcheck disable=SC2087 # client-side expansion is the point, see above
ssh "${ssh_opts[@]}" "$remote" 'bash -l -s' <<REMOTE || status=$?
set -uo pipefail
export CI_ATTR="path:$src#$attr" RESULT_FILE="$remote_result"
$runner bash "$src/scripts/ci-build.sh"
REMOTE

if [ -n "$local_result" ]; then
  scp "${ssh_opts[@]}" "$remote:$remote_result" "$local_result"
else
  echo "JUnit result left at $remote:$remote_result"
fi
exit "$status"
