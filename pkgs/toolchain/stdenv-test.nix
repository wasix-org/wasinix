# Per-profile test of the first-class cross stdenv (cc-wrapper around wasixcc,
# `toolchain.stdenv`). Unlike link-test.nix (which exercises wasixcc via the
# `commonPreConfigure` env-injection), this builds through a plain
# `stdenv.mkDerivation` — no CC=wasixcc exports — to prove the two things the
# stdenv path must deliver:
#   * a working $CC/$CXX (compile + link C++ with libc++ and exceptions), and
#   * automatic buildInputs → -I/-L/-l propagation (the consumer finds `libfoo`
#     purely via `buildInputs`, with no hand-written include/lib paths).
# Then it runs the result under wasmer (where the EH proposal allows).
#
# Takes the toolchain profile as an argument (rather than importing it) to stay
# clear of importing pkgs/toolchain (which would cycle).
{
  lib,
  wasmer,
  toolchain,
}: let
  stdenv = toolchain.stdenv;
  eh = (toolchain.wasmExceptions or "no") != "no";
  expect =
    if eh
    then 20
    else 15;
  # wasmer can't execute the *legacy* `try` opcode (no feature flag), so the
  # legacy-EH profiles are link-only — same gate as link-test.nix.
  canRun = (toolchain.wasmExceptions or "no") != "legacy";

  # A tiny static library built *with this stdenv*, installed in the normal
  # nixpkgs layout. The consumer below must discover it purely via buildInputs.
  libfoo = stdenv.mkDerivation {
    name = "wasix-stdenv-libfoo-${toolchain.profileName}";
    dontUnpack = true;
    buildPhase = ''
      runHook preBuild
      # extern "C" so the C library is callable from the C++ consumer below.
      printf '#ifdef __cplusplus\nextern "C" {\n#endif\nint foo_add(int, int);\n#ifdef __cplusplus\n}\n#endif\n' > foo.h
      printf 'int foo_add(int a, int b) { return a + b; }\n' > foo.c
      "$CC" -c foo.c -o foo.o
      "$AR" rcs libfoo.a foo.o
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      mkdir -p "$out/include" "$out/lib"
      cp foo.h "$out/include/"
      cp libfoo.a "$out/lib/"
      runHook postInstall
    '';
  };
in
  stdenv.mkDerivation {
    name = "wasix-stdenv-test-${toolchain.profileName}";
    dontUnpack = true;
    # The ONLY wiring to libfoo — no -I/-L/-lfoo spelled out by hand.
    buildInputs = [libfoo];

    buildPhase = ''
      runHook preBuild
      cat > main.cpp <<'CPP'
      #include <vector>
      #include <numeric>
      #include <foo.h>
      ${lib.optionalString eh "#include <stdexcept>"}
      int main() {
        std::vector<int> v{1, 2, 3, 4, 5};
        int s = std::accumulate(v.begin(), v.end(), 0);
      ${lib.optionalString eh ''try { throw std::runtime_error("boom"); } catch (const std::exception &) { s += 5; }''}
        return foo_add(s, 0) == ${toString expect} ? 0 : 1;
      }
      CPP
      "$CXX" main.cpp -lfoo -o main.wasm
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      magic="$(od -An -tx1 -N4 main.wasm | tr -d ' \n')"
      [ "$magic" = "0061736d" ] || {
        echo "not a wasm module (magic=$magic)"
        exit 1
      }

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

    meta.description = "first-class stdenv (cc-wrapper around wasixcc) build + buildInputs propagation test for the ${toolchain.profileName} profile";
  }
