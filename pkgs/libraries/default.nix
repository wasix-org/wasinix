{ nixpkgs, pkgsCross, toolchain }:
{
  ncurses = pkgsCross.callPackage ./ncurses {
    inherit nixpkgs toolchain;
  };
}
