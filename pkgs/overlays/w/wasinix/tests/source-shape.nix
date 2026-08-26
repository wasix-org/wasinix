{
  entry,
  pkgs,
  ...
}:
assert entry.package.unwrapped ? cargoArtifacts;
assert entry.package.unwrapped ? unit; {
  source-shape =
    pkgs.runCommand "wasinix-source-shape-check" {
      nativeBuildInputs = [pkgs.ripgrep];
    } ''
      if rg -n \
        'passthru\.wasix\.(shipped|ciProfiles|ciTags|emulatedCheck|installCheck|interpreterSpecific|publication|retention|smokeTest|testExpectation|updateNotes|postUpdateHook)|passthru\.wasmer\.(aliases|smokeArgs)|\bwasix\.(shipped|interpreterSpecific|retention|updateNotes|postUpdateHook)|helpers\.libTweaks|\blibTweaks\s*=' \
        ${../../../..}/pkgs; then
        echo "A removed Wasinix source shape is still in use" >&2
        exit 1
      fi
      if rg -n \
        --glob '!source-shape.nix' \
        'buildRustPackage|buildDepsOnly|buildPackage|cargoTest|unwrapped\.overrideAttrs' \
        ${./.}; then
        echo "Wasinix Rust builds must be defined in build.nix" >&2
        exit 1
      fi
      touch "$out"
    '';
}
