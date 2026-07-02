# Patch a fetchCargoVendor result so its vendored target-lexicon-0.13.* parses the wasix `dl`
# env (wasm32-wasmer-wasi-dl). pyo3-build-config and maturin parse the triple via target-lexicon,
# which panics on the unknown `dl` env; add the `Dl` variant and refresh .cargo-checksum.json.
# Fails loudly if the targets.rs layout stops matching. `pkgs` is the build-platform package set.
{pkgs}: cargoDeps:
pkgs.runCommand "vendor-target-lexicon-dl" {} ''
  cp -r ${cargoDeps} $out
  chmod -R +w $out
  shopt -s nullglob
  patched=
  for d in $out/*/target-lexicon-0.13.*; do
    f="$d/src/targets.rs"
    [ -f "$f" ] || continue
    grep -q '^    Eabihf,$' "$f" \
      || { echo "target-lexicon targets.rs layout changed — update vendor-target-lexicon-dl.nix" >&2; exit 1; }
    sed -i \
      -e 's/^    Eabihf,$/&\n    Dl,/' \
      -e 's@^            Eabihf => Cow::Borrowed("eabihf"),$@&\n            Dl => Cow::Borrowed("dl"),@' \
      -e 's/^            "eabihf" => Eabihf,$/&\n            "dl" => Dl,/' \
      "$f"
    new=$(sha256sum "$f" | cut -d' ' -f1)
    ${pkgs.jq}/bin/jq --arg h "$new" '.files["src/targets.rs"]=$h' \
      "$d/.cargo-checksum.json" > "$d/.cargo-checksum.json.new"
    mv "$d/.cargo-checksum.json.new" "$d/.cargo-checksum.json"
    patched=1
  done
  [ -n "$patched" ] || { echo "no vendored target-lexicon-0.13.* to patch" >&2; exit 1; }
''
