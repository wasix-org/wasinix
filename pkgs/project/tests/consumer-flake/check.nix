{
  importNixpkgs,
  pkgs,
  projectApi,
  root,
  system,
}: let
  project = import ./project.nix {
    inherit importNixpkgs root system;
    wasinixLib = projectApi;
  };
  publication = project.internals.repository.publication;
  apps = projectApi.appsForProject {
    inherit project;
    projectAttr = "legacyPackages.${system}";
  };
  paths = [
    {
      name = "consumer-tool";
      path = project.packages.native.consumer-tool;
    }
    {
      name = "consumer-wasm";
      path = project.packages.wasix.preferred.consumer-wasm;
    }
    {
      name = "consumer-webc";
      path = project.artifacts.webc.consumer-wasm;
    }
    {
      name = "wasinix";
      path = apps.wasinix.program;
    }
  ];
  validPublication =
    builtins.attrNames publication.catalog
    == ["artifacts.webc.consumer-wasm"]
    && publication.destinations.wasmer.registry == "wasmer.io"
    && publication.destinations.provenance.repository == "example/consumer";
in
  pkgs.lib.throwIf (!validPublication)
  "consumer project publication inventory does not match its repository declaration"
  (pkgs.linkFarm "wasinix-consumer-project" paths)
