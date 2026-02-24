{ nixpkgs, pkgs, pkgsCross, toolchain, libs }:
{
  nano = pkgsCross.callPackage ./nano/nano.nix {
    inherit nixpkgs toolchain;
    ncurses = libs.ncurses;
  };

  crabsay = pkgs.callPackage ./crabsay/crabsay.nix {
    cargoWasix = toolchain.cargoWasix;
  };
}
