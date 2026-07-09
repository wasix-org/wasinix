#!/usr/bin/env bash
# Single source of truth for *this machine's* remote nix builder. Reads
# `.remote-builder` (gitignored, see .remote-builder.example) and prints
# ready-to-use nix flags, so no script or agent ever hardcodes a host or key.
#
#   store    -> ssh-ng://host?ssh-key=...   (nix-fast-build --store, nix copy --to)
#   builders -> full --builders spec        (nix build --builders "$(...)" --max-jobs 0)
#   host     -> ssh target (user@hostname)
#   key      -> your ssh key path
#   check    -> exit 0 iff config present and host reachable over ssh
#
# Config is found at $WASINIX_BUILDER (a file path), else `.remote-builder` at
# the git top level.

set -euo pipefail

die() {
  echo "remote-builder: $*" >&2
  exit 1
}

find_config() {
  if [ -n "${WASINIX_BUILDER:-}" ]; then
    [ -f "$WASINIX_BUILDER" ] || die "WASINIX_BUILDER=$WASINIX_BUILDER is not a file"
    printf '%s\n' "$WASINIX_BUILDER"
    return
  fi
  local top
  top=$(git rev-parse --show-toplevel 2>/dev/null) || die "not in a git checkout and WASINIX_BUILDER unset"
  local f="$top/.remote-builder"
  [ -f "$f" ] || die "no $f; copy .remote-builder.example to .remote-builder and fill it in"
  printf '%s\n' "$f"
}

load() {
  local cfg
  cfg=$(find_config)
  # shellcheck disable=SC1090
  . "$cfg"
  [ -n "${HOST:-}" ] || die "HOST unset in $cfg"
  [ -n "${KEY:-}" ] || die "KEY unset in $cfg"
  KEY="${KEY/#\~/$HOME}" # expand a leading ~
  DAEMON_KEY="${DAEMON_KEY:-$KEY}"
  SYSTEM="${SYSTEM:-x86_64-linux}"
  MAXJOBS="${MAXJOBS:-1}"
  FEATURES="${FEATURES:-}"
  HOSTKEY="${HOSTKEY:--}"
}

mode="${1:-}"
case "$mode" in
host)
  load
  printf '%s\n' "$HOST"
  ;;
key)
  load
  printf '%s\n' "$KEY"
  ;;
store)
  load
  printf 'ssh-ng://%s?ssh-key=%s\n' "$HOST" "$KEY"
  ;;
builders)
  load
  printf 'ssh-ng://%s %s %s %s 2 %s - %s\n' \
    "$HOST" "$SYSTEM" "$DAEMON_KEY" "$MAXJOBS" "$FEATURES" "$HOSTKEY"
  ;;
check)
  load
  ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=8 \
    -o StrictHostKeyChecking=accept-new "$HOST" true ||
    die "cannot reach $HOST with $KEY"
  echo "ok: $HOST reachable"
  ;;
*)
  cat >&2 <<USAGE
usage: $0 {store|builders|host|key|check}
  store     ssh-ng URL for nix-fast-build --store / nix copy --to
  builders  full --builders spec (use with: nix build --builders "\$($0 builders)" --max-jobs 0)
  host      ssh target (user@hostname)
  key       your ssh key path
  check     verify the builder is configured and reachable
USAGE
  exit 64
  ;;
esac
