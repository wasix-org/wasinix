{ pkgs, wasmerPkgs }:
let
  lib = pkgs.lib;

  testLib = import ./lib.nix { inherit pkgs; };

  makeAll = name: tests:
    pkgs.runCommand "test-all-${name}" { } ''
      ${lib.concatMapStringsSep "\n"
        (n: "echo 'PASS: ${n}'; cat ${tests.${n}} > /dev/null")
        (builtins.attrNames tests)}
      touch $out
    '';

  importProgramTests = dir:
    let
      helpers =
        if builtins.pathExists "${dir}/helpers.nix"
        then import "${dir}/helpers.nix" { inherit pkgs; }
        else {};
      scope = { inherit pkgs wasmerPkgs testLib helpers; };
      testFiles = lib.filterAttrs (name: type:
        type == "regular" && lib.hasSuffix ".nix" name && name != "helpers.nix"
      ) (builtins.readDir dir);
    in
    builtins.foldl'
      (acc: name:
        let
          f = import "${dir}/${name}";
        in acc // f (builtins.intersectAttrs (lib.functionArgs f) scope))
      {}
      (builtins.attrNames testFiles);

  groups = lib.mapAttrs (name: _:
    let tests = importProgramTests ./programs/${name};
        all = makeAll name tests;
    in all // tests // { inherit all; }
  ) (lib.filterAttrs (_: type: type == "directory") (builtins.readDir ./programs));
in
  groups // { all = makeAll "all" (lib.mapAttrs (_: g: g.all) groups); }
