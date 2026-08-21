#!/usr/bin/env bash
set -euo pipefail

log=$1
baseline=$2
shard_count=${WASIX_CHECK_SHARD_COUNT:-1}
shard_num=${WASIX_CHECK_SHARD_NUM:-0}
work=${TMPDIR:?}/php-upstream-results
actual=$work/actual
expected=$work/expected
normalized=$work/normalized
unexpected=$work/unexpected

mkdir -p "$work"
grep -q '^TEST RESULT SUMMARY$' "$log" || {
  echo "PHP test output has no result summary" >&2
  exit 1
}

awk '
  BEGIN { OFS = "\t" }
  /^(BORKED|FAILED|LEAKED) TEST SUMMARY$/ { kind = $1; next }
  /^=+$/ { kind = ""; next }
  kind != "" {
    line = $0
    if (line ~ /\[[^]]+\.phpt[^]]*\]$/) {
      sub(/^.*\[/, "", line)
      sub(/\]$/, "", line)
      sub(/^\/build\/source\//, "", line)
      print kind, line
    }
  }
' "$log" | LC_ALL=C sort -u >"$actual"

summary_count=$(awk '
  /^Tests (borked|failed|leaked) +:/ { total += $4 }
  END { print total + 0 }
' "$log")
actual_count=$(wc -l <"$actual")
[ "$actual_count" -eq "$summary_count" ] || {
  echo "parsed $actual_count PHP failures, but the summary reports $summary_count" >&2
  exit 1
}

LC_ALL=C sort -u "$baseline" >"$normalized"
cmp -s "$baseline" "$normalized" || {
  echo "PHP upstream baseline must be sorted and contain no duplicates: $baseline" >&2
  exit 1
}

: >"$expected"
while IFS=$'\t' read -r kind path extra; do
  case "$kind" in
  BORKED | FAILED | LEAKED) ;;
  *)
    echo "invalid PHP upstream result class '$kind' in $baseline" >&2
    exit 1
    ;;
  esac
  [ -n "$path" ] && [ -z "${extra:-}" ] || {
    echo "invalid PHP upstream baseline line: $kind $path ${extra:-}" >&2
    exit 1
  }
  digest=$(printf %s "$path" | sha256sum)
  bucket=$((16#${digest:0:6} % shard_count))
  if [ "$bucket" -eq "$shard_num" ]; then
    printf '%s\t%s\n' "$kind" "$path" >>"$expected"
  fi
done <"$baseline"

comm -23 "$actual" "$expected" >"$unexpected"
if [ -s "$unexpected" ]; then
  cat "$unexpected" >&2
  echo "PHP upstream suite has failures outside the checked-in baseline" >&2
  exit 1
fi

printf 'PHP upstream failures are covered by %s for shard %s of %s\n' \
  "$(basename "$baseline")" "$shard_num" "$shard_count"
