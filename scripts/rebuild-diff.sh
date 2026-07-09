#!/usr/bin/env bash
# Eval the CI job map (attr -> drvPath), diff it against the base branch's
# published map to surface what this change rebuilds, and emit the update notes.
# Run in CI (build.yml) via `nix run .#scripts.rebuild-diff`, which provides
# python3. Informational, so failures fall back to empty rather than aborting.
# Reads GHA env: GITHUB_SHA, GITHUB_STEP_SUMMARY, and BASE_REF (set by the
# workflow from the pull_request / merge_group base).
set -uo pipefail

candidates=()
if [ -n "${BASE_REF:-}" ]; then
  # walk back: the newest base commits may not have published yet
  git fetch --quiet --depth=30 origin "$BASE_REF"
  mapfile -t candidates < <(git rev-list -n 30 FETCH_HEAD)
fi

# update notes: current versions ride in the map; the base map's copy comes back
# as the `prior` side of each note's predicate
sys=$(nix eval --raw --impure --expr 'builtins.currentSystem')
nix eval --json ".#legacyPackages.$sys.updateNotes.versions" \
  --option accept-flake-config true >note-versions.json ||
  echo '{}' >note-versions.json

python3 scripts/eval-diff.py \
  --rev "$GITHUB_SHA" \
  --jobs-out eval-jobs.jsonl \
  --map-out eval-map.json \
  --md-out rebuild-diff.md \
  --summary-out diff-summary.json \
  --base-map-out base-map.json \
  --note-versions note-versions.json \
  --priors-out note-priors.json \
  --base-rev "${candidates[@]}"

cat rebuild-diff.md >>"$GITHUB_STEP_SUMMARY"

NOTE_PRIORS=$(cat note-priors.json) nix eval --json --impure \
  ".#legacyPackages.$sys.updateNotes.fired" \
  --apply 'f: f (builtins.fromJSON (builtins.getEnv "NOTE_PRIORS"))' \
  --option accept-flake-config true >update-notes.json ||
  echo '{}' >update-notes.json
