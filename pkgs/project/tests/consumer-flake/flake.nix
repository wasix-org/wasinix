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
    project = import ./project.nix {
      inherit system;
      importNixpkgs = args: import nixpkgs args;
      root = self;
      wasinixLib = wasinix.lib;
    };
  in {
    apps.${system} = wasinix.lib.appsForProject {inherit project projectAttr;};
    legacyPackages.${system} = project;
    packages.${system}.default = project.packages.native.consumer-tool;
  };
}
