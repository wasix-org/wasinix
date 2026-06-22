{
  makeWasmerPackage,
  phpixPhp85,
}: let
  mkPhpixWasmer = import ./mk-phpix-wasmer.nix {
    inherit makeWasmerPackage;
  };
in
  mkPhpixWasmer {
    name = "phpixPhp85";
    package = phpixPhp85;
  }
