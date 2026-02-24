{ lib, pkgs, nanoWasmer, grepWasmer, sedWasmer, findWasmer, gzipWasmer, tarWasmer, ncursesWasmer, crabsayWasmer, cliPlatformWasmer }:
let
  packages = {
    nano = nanoWasmer;
    grep = grepWasmer;
    sed = sedWasmer;
    find = findWasmer;
    gzip = gzipWasmer;
    tar = tarWasmer;
    ncurses = ncursesWasmer;
    crabsay = crabsayWasmer;
    cliPlatform = cliPlatformWasmer;
  };

  allWasmer = pkgs.runCommand "wasix-all-wasmer" { } ''
    set -euo pipefail
    mkdir -p "$out/pkg"
    ${lib.concatMapStringsSep "\n" (attrName: ''
      if [ -d "${packages.${attrName}}/pkg" ]; then
        # Do not preserve top-level directory permissions from Nix store paths.
        ${pkgs.coreutils}/bin/cp -R --no-preserve=mode,ownership "${packages.${attrName}}/pkg/." "$out/pkg/"
      fi
    '') (builtins.attrNames packages)}
  '';
in
{
  inherit packages allWasmer;
}
