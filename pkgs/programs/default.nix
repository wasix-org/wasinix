{ nixpkgs, pkgs, pkgsCross, toolchain, libs }:
{
  nano = pkgsCross.callPackage ./nano/nano.nix {
    inherit nixpkgs toolchain;
    ncurses = libs.ncurses;
  };
  grep = pkgsCross.callPackage ./grep/grep.nix {
    inherit toolchain;
  };

  crabsay = pkgs.callPackage ./crabsay/crabsay.nix {
    cargoWasix = toolchain.cargoWasix;
  };
}
