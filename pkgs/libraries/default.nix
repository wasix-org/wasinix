{ nixpkgs, pkgsCross, toolchain }:
{
  ncursesLib = pkgsCross.callPackage ./ncurses {
    inherit nixpkgs toolchain;
  };
}
