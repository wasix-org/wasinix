{
  inputs = {
    wasinix.url = "github:wasix-org/wasinix";
    nixpkgs.follows = "wasinix/nixpkgs";
  };

  outputs = {
    self,
    nixpkgs,
    wasinix,
  }: let
    system = "x86_64-linux";
    projectAttr = "legacyPackages.${system}";
    project = wasinix.lib.mkProject {
      inherit system;
      importNixpkgs = args: import nixpkgs args;
      repository = {
        source = "consumer";
        root = self;
        revisionsFile = ./release-revisions.json;
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
            consumer-wasm =
              final.runCommand "consumer-wasm-1.0.0" {
                passthru.wasinix.shipped = final.stdenv.hostPlatform.isWasix or false;
                meta.mainProgram = "consumer-wasm";
              } ''
                mkdir -p "$out/bin"
                touch "$out/bin/consumer-wasm.wasm"
              '';
          };
        }
      ];
    };
  in {
    apps.${system} = wasinix.lib.appsForProject {inherit project projectAttr;};
    legacyPackages.${system} = project;
    packages.${system}.default = project.packages.native.consumer-tool;
  };
}
