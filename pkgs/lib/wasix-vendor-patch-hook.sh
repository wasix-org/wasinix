# preBuild hook: apply the versioned crate-patch tree (@patchesDir@) to vendored
# crate sources so stock upstream Rust builds unchanged for wasix. Semver floor:
# for <crate>-<V>, apply the highest patch version <= V. See wasix-crate-patches/README.md.

_wasixRefreshChecksum() { # <cratedir> <relpath>
  local d="$1" f="$2" h
  if [ -f "$d/$f" ]; then
    h=$(sha256sum "$d/$f" | cut -d' ' -f1)
    jq --arg f "$f" --arg h "$h" '.files[$f]=$h' "$d/.cargo-checksum.json" >"$d/.cc.tmp"
  else
    jq --arg f "$f" 'del(.files[$f])' "$d/.cargo-checksum.json" >"$d/.cc.tmp"
  fi
  mv "$d/.cc.tmp" "$d/.cargo-checksum.json"
}

# Echo the highest patch version <= $2 for crate $1, or nothing.
_wasixSelectPatch() {
  local crate="$1" ver="$2" best="" bestver="" pf pv
  for pf in "@patchesDir@/$crate"/*.patch; do
    [ -e "$pf" ] || continue
    pv=$(basename "$pf" .patch)
    [ "$(printf '%s\n%s\n' "$pv" "$ver" | sort -V | tail -1)" = "$ver" ] || continue
    if [ -z "$bestver" ] || [ "$(printf '%s\n%s\n' "$pv" "$bestver" | sort -V | tail -1)" = "$pv" ]; then
      best="$pf"
      bestver="$pv"
    fi
  done
  # Must return 0 (empty is fine): non-zero aborts the build under `set -e` via pf=$(...).
  printf '%s' "$best"
}

_wasixApplyCratePatches() { # <vendor>
  local vendor="$1" cratedir crate vd base ver pf f
  shopt -s nullglob
  for cratedir in "@patchesDir@"/*/; do
    crate=$(basename "$cratedir")
    while IFS= read -r vd; do
      base=$(basename "$vd")
      ver=${base#"$crate"-}
      # skip near-name crates (tokio vs tokio-util): the suffix must be a bare semver
      [[ $ver =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ ]] || continue
      pf=$(_wasixSelectPatch "$crate" "$ver")
      [ -n "$pf" ] || continue
      echo "wasix: $base <- $(basename "$pf")"
      patch -p1 -d "$vd" --no-backup-if-mismatch <"$pf" || {
        echo "wasix: $(basename "$pf") did not apply to $base; add a matching <version>.patch" >&2
        exit 1
      }
      while IFS= read -r f; do
        [ "$f" = /dev/null ] && continue
        _wasixRefreshChecksum "$vd" "$f"
      done < <(grep -hE '^(\+\+\+|---) [ab]/' "$pf" | sed -E 's|^(\+\+\+|---) [ab]/||' | sort -u)
    done < <(find "$vendor" -maxdepth 2 -type d -name "$crate-*")
  done
}

_wasixVendorPatch() {
  [ -n "${_wasixVendorPatchDone:-}" ] && return 0 # once; a second pass fails on applied hunks
  _wasixVendorPatchDone=1
  local cfg base vendor rp found=
  declare -A seen
  # cargoSetupHook records the writable vendor copy in .cargo/config.toml's `directory=`;
  # it lands at sourceRoot or the build top, so search the tree and resolve a relative
  # path against the config's own dir. Patch each dir once.
  while IFS= read -r -d "" cfg; do
    base=$(cd "$(dirname "$(dirname "$cfg")")" && pwd)
    while IFS= read -r vendor; do
      case "$vendor" in /*) : ;; *) vendor="$base/$vendor" ;; esac
      [ -d "$vendor" ] || continue
      rp=$(realpath "$vendor")
      [ -n "${seen[$rp]:-}" ] && continue
      seen[$rp]=1
      found=1
      chmod -R u+w "$rp" 2>/dev/null || true
      _wasixApplyCratePatches "$rp"
    done < <(sed -n 's/^[[:space:]]*directory = "\(.*\)"/\1/p' "$cfg")
  done < <(find "${NIX_BUILD_TOP:-.}" -maxdepth 4 -name config.toml -path '*/.cargo/*' -print0 2>/dev/null)
  [ -n "$found" ] || echo "wasix: no vendored-sources directory found; nothing patched" >&2
}

preBuildHooks+=(_wasixVendorPatch)
