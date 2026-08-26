{
  importNixpkgs,
  root,
  system,
  wasinixLib,
}:
wasinixLib.mkProject {
  inherit system importNixpkgs;
  repository = {
    source = "consumer";
    inherit root;
    revisionsFile = root + "/release-revisions.json";
    publication = {
      wasmer.registry = "wasmer.io";
      provenance = {
        flake = "github:example/consumer";
        repository = "example/consumer";
      };
    };
  };
  extensions = [
    {
      id = "consumer";
      overlays.packages = final: _previous: {
        consumer-tool =
          final.runCommand "consumer-tool" {
            passthru.wasix.supportedProfiles = [];
          } ''
            mkdir -p "$out/bin"
            printf '#!/bin/sh\nprintf consumer\\n' > "$out/bin/consumer-tool"
            chmod +x "$out/bin/consumer-tool"
          '';
        consumer-wasm = final.stdenv.mkDerivation {
          pname = "consumer-wasm";
          version = "1.0.0";
          dontUnpack = true;
          passthru.wasinix.shipped = final.stdenv.hostPlatform.isWasix or false;
          meta.mainProgram = "consumer-wasm";
          buildPhase = ''
            runHook preBuild
            $CC ${root + "/consumer.c"} -o consumer-wasm
            runHook postBuild
          '';
          installPhase = ''
            runHook preInstall
            mkdir -p "$out/bin"
            install -m755 consumer-wasm "$out/bin/consumer-wasm${final.lib.optionalString (final.stdenv.hostPlatform.isWasix or false) ".wasm"}"
            runHook postInstall
          '';
        };
      };
    }
  ];
}
