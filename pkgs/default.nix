{ system, nixpkgs }:
let
  pkgs = import nixpkgs { inherit system; };
  inherit (pkgs) lib;
  toolchainPkgs = import ./toolchain { inherit pkgs; };
  mkToolchainProfile = pkgs.callPackage ./toolchain/mk-profile.nix {
    inherit toolchainPkgs;
  };

  toolchains = {
    eh = mkToolchainProfile {
      name = "eh";
      wasmExceptions = "legacy";
    };
    ehpic = mkToolchainProfile {
      name = "ehpic";
      wasmExceptions = "legacy";
      pic = true;
    };
    exnrefEh = mkToolchainProfile {
      name = "exnrefEh";
      wasmExceptions = "yes";
    };
    exnrefEhpic = mkToolchainProfile {
      name = "exnrefEhpic";
      wasmExceptions = "yes";
      pic = true;
    };
  };
  defaultProfileName = "exnrefEh";
  defaultToolchain = toolchains.${defaultProfileName};

  pkgsCross = import nixpkgs {
    inherit system;
    crossSystem = defaultToolchain.crossSystem;
    config.allowUnsupportedSystem = true;
  };

  libraries = lib.mapAttrs (profileName: toolchain:
    import ./libraries {
      inherit nixpkgs pkgs pkgsCross toolchain;
      # includePhp = profileName == defaultProfileName;
      includePhp = false;
    }
  ) toolchains;

  defaultLibraries = libraries.${defaultProfileName};

  programs = import ./programs {
    nixpkgs = nixpkgs;
    inherit pkgs pkgsCross;
    libraries = defaultLibraries;
    toolchain = defaultToolchain;
  };

  makeWasmerPackage = pkgs.callPackage ./wasmer/make-wasmer-package.nix { };
  makePlainWasmerPackage = pkgs.callPackage ./wasmer/make-plain-wasmer-package.nix { };

  nanoWasmer = pkgs.callPackage ./programs/nano/nanoWasmer.nix {
    inherit makeWasmerPackage;
    nano = programs.nano;
  };
  grepWasmer = pkgs.callPackage ./programs/grep/grepWasmer.nix {
    inherit makeWasmerPackage;
    grep = programs.grep;
  };
  sedWasmer = pkgs.callPackage ./programs/sed/sedWasmer.nix {
    inherit makeWasmerPackage;
    sed = programs.sed;
  };
  findWasmer = pkgs.callPackage ./programs/find/findWasmer.nix {
    inherit makeWasmerPackage;
    find = programs.find;
  };
  gzipWasmer = pkgs.callPackage ./programs/gzip/gzipWasmer.nix {
    inherit makeWasmerPackage;
    gzip = programs.gzip;
  };
  tarWasmer = pkgs.callPackage ./programs/tar/tarWasmer.nix {
    inherit makeWasmerPackage;
    tar = programs.tar;
  };
  lessWasmer = pkgs.callPackage ./programs/less/lessWasmer.nix {
    inherit makeWasmerPackage;
    less = programs.less;
  };
  ncursesWasmer = pkgs.callPackage ./programs/ncurses/ncursesWasmer.nix {
    inherit makeWasmerPackage;
    ncurses = programs.ncurses;
  };
  crabsayWasmer = pkgs.callPackage ./programs/crabsay/crabsayWasmer.nix {
    inherit makeWasmerPackage;
    crabsay = programs.crabsay;
  };
  curlWasmer = pkgs.callPackage ./programs/curl/curlWasmer.nix {
    inherit makeWasmerPackage;
    curl = programs.curl;
  };
  shShimWasmer = pkgs.callPackage ./programs/sh-shim/shWasmer.nix {
    inherit makeWasmerPackage;
    shShim = programs.shShim;
  };
  gettextWasmer = pkgs.callPackage ./programs/gettext/gettextWasmer.nix {
    inherit makeWasmerPackage;
    gettext = programs.gettext;
  };
  gitWasmer = pkgs.callPackage ./programs/git/gitWasmer.nix {
    inherit makeWasmerPackage;
    git = programs.git;
  };

  # phpixPhp83Wasmer = pkgs.callPackage ./programs/phpix/phpixPhp83Wasmer.nix {
  #   inherit makeWasmerPackage;
  #   phpixPhp83 = programs.phpixPhp83;
  # };
  # phpixPhp85Wasmer = pkgs.callPackage ./programs/phpix/phpixPhp85Wasmer.nix {
  #   inherit makeWasmerPackage;
  #   phpixPhp85 = programs.phpixPhp85;
  # };

  cliPlatformWasmer = pkgs.callPackage ./wasmer/cli-platform.nix {
    inherit makePlainWasmerPackage;
  };

  wasmer = import ./wasmer {
    inherit (pkgs) lib;
    inherit pkgs nanoWasmer grepWasmer sedWasmer findWasmer gzipWasmer tarWasmer lessWasmer ncursesWasmer crabsayWasmer curlWasmer shShimWasmer gettextWasmer gitWasmer cliPlatformWasmer;
  };

  allPackages = defaultLibraries // programs;
  allWasmPackages = allPackages;

  allWasm = pkgs.runCommand "wasix-all-wasm" {} ''
    mkdir -p "$out/bin"
    ${pkgs.lib.concatMapStringsSep "\n" (name: ''
      if [ -d "${allWasmPackages.${name}}/bin" ]; then
        ${pkgs.findutils}/bin/find "${allWasmPackages.${name}}/bin" -maxdepth 1 -type f -name '*.wasm' \
          -exec ${pkgs.coreutils}/bin/cp -f '{}' "$out/bin/" \;
      fi
    '') (builtins.attrNames allWasmPackages)}
  '';
in
{
  inherit pkgs pkgsCross toolchains libraries programs wasmer allPackages allWasm defaultProfileName;
}
