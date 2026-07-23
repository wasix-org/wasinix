#!/usr/bin/env bash
# Spot-override driver: build one or more attrs from the working tree with
# everything below them pinned to a cached base revision. See ../spot.nix.
#
#   scripts/spot.sh exnrefEh.zlib                       # cc/rust/haskell toolchain experiment
#   scripts/spot.sh --keep toolchain,zlib exnrefEh.curl # edit a common dep, test one package
#   scripts/spot.sh --keep zlib exnrefEh.curl           # ...isolated from any toolchain diff
#   scripts/spot.sh --dry-run exnrefEhpic.python314
#
# Local experiment tool: the output mixes two toolchains, so a green build is
# evidence, not proof.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
base=HEAD
keep='' # unset; pkgs/spot.nix owns the default, so it is not restated here
dry=0
remote=1
targets=()

usage() {
  cat >&2 <<'EOF'
usage: spot.sh [--base REV] [--keep NAME,...] [--local] [--dry-run] TARGET... [-- nix args...]

  TARGET   dotted attr path into nixpkgsByProfile, e.g. exnrefEh.zlib. Pass more
           than one to build them from a single splice; each target's own attr is
           kept, so co-tested targets see each other on the working tree.
  --base   pristine revision to pin below the targets (default: HEAD).
           Pick a revision CI has built, or the pins come from nowhere.
  --keep   set of attrs to build from the working tree; everything else comes
           from base. Terms are attr names or aliases (cc = wasixcc, rust =
           cargo-wasix, haskell = ghc-wasm, toolchain = the three, all = every
           attr, none = empty). A "-" prefix removes from what precedes it:
           --keep toolchain,zlib or --keep all,-rust. Defaults to `toolchain`.
           The targets are always kept. Cost tracks what your change actually
           moved, not the keep size; the dry-run plan shows it.
  --local  build on this machine instead of the remote builder. The default is
           remote (the toolchain closure is large); use this when no remote
           builder is configured or the target is cheap.
EOF
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
  --base)
    base=$2
    shift 2
    ;;
  # Raw tokens; pkgs/spot.nix expands aliases (cc/rust/haskell/all) and rejects
  # unknown names, so both entry points share one grammar.
  --keep)
    keep=$(printf '%s' "$2" | awk -F, '{printf "["; for(i=1;i<=NF;i++) printf "\"%s\" ", $i; printf "]"}')
    shift 2
    ;;
  --local)
    remote=0
    shift
    ;;
  --dry-run)
    dry=1
    shift
    ;;
  --)
    shift
    break
    ;;
  -h | --help) usage ;;
  -*) usage ;;
  *)
    targets+=("$1")
    shift
    ;;
  esac
done
[ ${#targets[@]} -gt 0 ] || usage

# The base must be a resolved rev: the flake fetcher needs one, and pinning to a
# moving ref would silently change what "below" means between runs.
rev=$(git -C "$root" rev-parse --verify "$base^{commit}")

targets_nix="[$(printf '"%s" ' "${targets[@]}")]"
args=(-f "$root/spot.nix" --impure --arg targets "$targets_nix" --argstr base "$rev")
[ -n "$keep" ] && args+=(--arg keep "$keep")

echo "spot: ${targets[*]}   base=${rev:0:12} keep=${keep:-(default)}" >&2

# Refuse a no-op: if nothing about the target changed, the pins are the whole
# story and the build would just re-download base's own output. An eval failure
# is reported as itself, not as a no-op.
# stderr to a file, not into the variable: nix warns about the dirty tree on
# every run, and folding that into the value makes the comparison below false.
err=$(mktemp)
trap 'rm -f "$err"' EXIT
if ! changed=$(nix eval "${args[@]}" report.changed 2>"$err"); then
  echo "spot: evaluating the splice failed:" >&2
  cat "$err" >&2
  exit 1
fi
if [ "$changed" != "true" ]; then
  echo "spot: every target is identical to base; the working tree does not reach them." >&2
  echo "      A toolchain edit reaches any target by default. For a change to a" >&2
  echo "      dependency, add it: --keep toolchain,<pkg>. Check the change is in a" >&2
  echo "      tracked file, and that --keep still lists what you edited." >&2
  exit 1
fi

if [ "$dry" = 1 ]; then
  # Two counts, because "N to build" alone conflates two things: the compiles
  # your change causes, and base artifacts that were never cached. `base rev`
  # should be 0 (a CI-built base is all fetchable from the cache); if it is not,
  # most of `this run` is rebuilding base, not testing the change, so pick a
  # revision CI has built.
  # nix says "these N derivations will be built" for N>1 but "this derivation
  # will be built" for exactly one; count both, else a 1-build plan reports 0.
  builds() {
    nix build "${args[@]}" "$1" --dry-run 2>&1 | sed -n \
      -e 's/^these \([0-9]*\) derivations will be built.*/\1/p' \
      -e 's/^this derivation will be built.*/1/p'
  }
  base_builds=$(builds baseDrv)
  run_builds=$(builds spliced)
  echo "spot: base rev   ${base_builds:-0} to build   (want 0; nonzero = --base not cached)" >&2
  echo "spot: this run   ${run_builds:-0} to build" >&2
  exec nix build "${args[@]}" spliced --dry-run "$@"
fi

if [ "$remote" = 0 ]; then
  exec nix build "${args[@]}" spliced --print-build-logs "$@"
fi

# Remote by default: a toolchain experiment rebuilds the compiler wrappers, and
# the base closure it pulls is large.
builders=$("$root/scripts/remote-builder.sh" builders)
exec nix build "${args[@]}" spliced \
  --max-jobs 0 --builders "$builders" --builders-use-substitutes \
  --print-build-logs "$@"
