{ lib, pkgs, nanoWasmer }:
let
  packages = {
    inherit nanoWasmer;
  };

  allWasmer = pkgs.runCommand "wasix-all-wasmer" { } ''
    set -euo pipefail
    mkdir -p "$out/pkg"
    ${lib.concatMapStringsSep "\n" (attrName: ''
      if [ -d "${packages.${attrName}}/pkg" ]; then
        ${pkgs.coreutils}/bin/cp -a "${packages.${attrName}}/pkg/." "$out/pkg/"
      fi
    '') (builtins.attrNames packages)}
  '';
in
{
  inherit packages allWasmer;
}
