{
  lib,
  stdenvNoCC,
  rustPlatform,
  cargoWasix,
  gcc,
  llvmPackages,
  php85ZTS,
  toolchain,
}: let
  mkPhpixWasix = import ./mk-phpix-wasix.nix {
    inherit
      lib
      stdenvNoCC
      rustPlatform
      cargoWasix
      gcc
      llvmPackages
      toolchain
      ;
  };
in
  mkPhpixWasix {
    pname = "phpix-php85";
    version = "0.1.12803";
    src = ../../../vendor/phpix;
    cargoLock = ./phpix.Cargo.lock;
    phpPackage = php85ZTS;
    meta.description = "PHPix server for WASIX built against PHP 8.5 static libphp";
  }
