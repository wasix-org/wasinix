{
  lib,
  stdenvNoCC,
  rustPlatform,
  cargoWasix,
  gcc,
  llvmPackages,
  php83ZTS,
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
    pname = "phpix-php83";
    version = "0.1.12803";
    src = ../../../vendor/phpix;
    cargoLock = ./phpix.Cargo.lock;
    phpPackage = php83ZTS;
    meta.description = "PHPix server for WASIX built against PHP 8.3 static libphp";
  }
