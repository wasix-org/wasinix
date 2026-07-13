# Patch a vendored cargo deps dir so its target-lexicon-0.13.* parses the wasix `dl`
# env (wasm32-wasmer-wasi-dl). pyo3-build-config and maturin parse the triple via target-lexicon,
# which panics on the unknown `dl` env; add the `Dl` variant and refresh .cargo-checksum.json.
# Crates live at depth 1 (importCargoLock's flat cargo-vendor-dir) or depth 2
# (fetchCargoVendor's source-registry-0/), so search both. importCargoLock's
# entries are symlinks into per-crate store paths, so dereference with `cp -rL`
# to get real writable dirs. Fails loudly if the targets.rs layout stops
# matching. `pkgs` is the build-platform package set.
#
# Keep the output name identical to the input: importCargoLock bakes a relative
# `directory = "cargo-vendor-dir"` into .cargo/config.toml and cargoSetupHook
# unpacks to /build/<store-path-basename>, so renaming would break that path
# (fetchCargoVendor is name-agnostic, so preserving the name is safe for it too).
{pkgs}: cargoDeps:
pkgs.runCommand cargoDeps.name {} ''
  cp -rL ${cargoDeps} $out
  chmod -R +w $out
  patched=
  while IFS= read -r d; do
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
  done < <(find $out -maxdepth 2 -type d -name 'target-lexicon-0.13.*')
  [ -n "$patched" ] || { echo "no vendored target-lexicon-0.13.* to patch" >&2; exit 1; }
''
