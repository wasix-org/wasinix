{ nixpkgs, pkgsCross, toolchain, libs }:
{
  nano = pkgsCross.callPackage ./nano/nano.nix {
    inherit nixpkgs toolchain;
    ncurses = libs.ncurses;
  };
}
