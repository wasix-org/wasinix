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
  paths =
    pkgs.lib.mapAttrsToList (name: path: {inherit name path;}) project.ci.jobs
    ++ [
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
