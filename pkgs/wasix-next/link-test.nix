# End-to-end link + run test for one toolchain profile: compile + link a small C++
# program with that profile's wasixcc (which selects the matching sysroot variant
# and handles builtins/crt/EH/PIC linking), then *run* it under wasmer. The program
# returns 0 only when its result is correct, so a clean wasmer exit validates the
# whole chain — compile → link → execute — against the from-source toolchain+sysroot.
#
# Takes the toolchain profile as an argument (rather than importing it), so it stays
# free of the toolchain → wasix-next import cycle.
{
  lib,
  stdenvNoCC,
  wasmer,
  toolchain,
}: let
  eh = (toolchain.wasmExceptions or "no") != "no";
  expect =
    if eh
    then 20
    else 15;
  # wasmer runs the exnref EH proposal (and no-EH) by default, but can't execute
  # the *legacy* `try` opcode (no feature flag for it), so the legacy-EH profiles
  # are link-only — the toolchain/sysroot are still fully exercised by the link.
  canRun = (toolchain.wasmExceptions or "no") != "legacy";
in
  stdenvNoCC.mkDerivation {
    name = "wasix-link-test-${toolchain.profileName}";
    dontUnpack = true;

    buildPhase = ''
      runHook preBuild
      ${toolchain.commonPreConfigure}
      cat > main.cpp <<'CPP'
      #include <vector>
      #include <numeric>
      ${lib.optionalString eh "#include <stdexcept>"}
      int main() {
        std::vector<int> v{1, 2, 3, 4, 5};
        int s = std::accumulate(v.begin(), v.end(), 0);
      ${lib.optionalString eh ''try { throw std::runtime_error("boom"); } catch (const std::exception &) { s += 5; }''}
        return s == ${toString expect} ? 0 : 1;
      }
      CPP
      "$CXX" main.cpp -o main.wasm
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      magic="$(od -An -tx1 -N4 main.wasm | tr -d ' \n')"
      [ "$magic" = "0061736d" ] || { echo "not a wasm module (magic=$magic)"; exit 1; }

      ${
        if canRun
        then ''
          export HOME="$TMPDIR"
          export WASMER_DIR="$TMPDIR/.wasmer"
          ${wasmer}/bin/wasmer run main.wasm
          echo "ran OK under wasmer"
        ''
        else ''echo "link-only (legacy-EH: wasmer can't execute the legacy try opcode)"''
      }

      mkdir -p "$out"
      cp main.wasm "$out/"
      runHook postInstall
    '';

    meta.description = "wasixcc link + run test for the ${toolchain.profileName} profile";
  }
