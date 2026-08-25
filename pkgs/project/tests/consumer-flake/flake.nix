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
      extensions = [
        {
          id = "consumer";
          overlays.native = final: _previous: {
            consumer-tool = final.runCommand "consumer-tool" {} ''
              mkdir -p "$out/bin"
              printf '#!/bin/sh\nprintf consumer\\n' > "$out/bin/consumer-tool"
              chmod +x "$out/bin/consumer-tool"
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
