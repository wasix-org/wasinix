{pkgs, ...}: {
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
      touch "$out"
    '';
}
