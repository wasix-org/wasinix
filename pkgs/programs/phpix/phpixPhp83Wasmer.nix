{
  makeWasmerPackage,
  phpixPhp83,
}: let
  mkPhpixWasmer = import ./mk-phpix-wasmer.nix {
    inherit makeWasmerPackage;
  };
in
  mkPhpixWasmer {
    name = "phpixPhp83";
    package = phpixPhp83;
  }
