{
  entry,
  pkgs,
  ...
}: let
  root = ../../../..;
  helperFiles =
    pkgs.lib.concatLists
    (builtins.attrValues (fromTOML (builtins.readFile ../../../helper-boundaries.toml)));
  source = pkgs.lib.fileset.toSource {
    inherit root;
    fileset = pkgs.lib.fileset.unions (
      [
        ../../../../.github
        ../../../../flake.nix
        ../../../../schema/project.json
        ../../../helper-boundaries.toml
        ../../../../tools/wasinix
      ]
      ++ map (path: root + "/${path}") helperFiles
    );
  };
in {
  unit = entry.package.unwrapped.overrideAttrs (_old: {
    src = source;
    sourceRoot = "${source.name}/tools/wasinix";
    doCheck = true;
    nativeCheckInputs = [pkgs.gitMinimal pkgs.nixVersions.latest];
  });
}
