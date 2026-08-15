# End-to-end test for one profile: compile + link a small C++ program with that
# profile's wasixcc, then run it under wasmer. The program returns 0 only when
# its result is correct, so a clean exit validates compile, link, and execute.
#
# Takes the toolchain profile as an argument; importing pkgs/toolchain here
# would cycle.
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
  # wasmer can't execute the *legacy* `try` opcode (no feature flag for it), so
  # legacy-EH profiles are link-only; the link still exercises toolchain + sysroot.
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
          ${wasmer}/bin/wasmer run --quiet main.wasm
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
