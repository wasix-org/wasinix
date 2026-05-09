<<<<<<< HEAD
{ lib, pkgs, nanoWasmer, grepWasmer, sedWasmer, findWasmer, gzipWasmer, tarWasmer, lessWasmer, ncursesWasmer, crabsayWasmer, cliPlatformWasmer }:
=======
{ lib, pkgs, nanoWasmer, grepWasmer, sedWasmer, findWasmer, gzipWasmer, tarWasmer, lessWasmer, ncursesWasmer, crabsayWasmer, curlWasmer, cliPlatformWasmer }:
>>>>>>> 5c2b714 (fixup! programs/curl: init)
let
  packages = {
    nano = nanoWasmer;
    grep = grepWasmer;
    sed = sedWasmer;
    find = findWasmer;
    gzip = gzipWasmer;
    tar = tarWasmer;
    less = lessWasmer;
    ncurses = ncursesWasmer;
    crabsay = crabsayWasmer;
<<<<<<< HEAD
=======
    curl = curlWasmer;
>>>>>>> 5c2b714 (fixup! programs/curl: init)
    # phpixPhp83 = phpixPhp83Wasmer;
    # phpnixPhp83 = phpixPhp83Wasmer;
    # phpixPhp85 = phpixPhp85Wasmer;
    # phpnixPhp85 = phpixPhp85Wasmer;
    cliPlatform = cliPlatformWasmer;
  };
  allWasmerPackages = packages;

  allWasmer = pkgs.runCommand "wasix-all-wasmer" { } ''
    set -euo pipefail
    mkdir -p "$out/pkg"
    ${lib.concatMapStringsSep "\n" (attrName: ''
      if [ -d "${allWasmerPackages.${attrName}}/pkg" ]; then
        # Do not preserve top-level directory permissions from Nix store paths.
        ${pkgs.coreutils}/bin/cp -R --no-preserve=mode,ownership "${allWasmerPackages.${attrName}}/pkg/." "$out/pkg/"
      fi
    '') (builtins.attrNames allWasmerPackages)}
  '';
in
{
  inherit packages allWasmer;
}
