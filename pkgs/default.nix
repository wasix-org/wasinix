{
  system,
  nixpkgs,
}: let
  pkgs = import nixpkgs {inherit system;};
  inherit (pkgs) lib;
  toolchainPkgs = import ./toolchain {inherit pkgs;};

  # The single wasix cross target. Kept here (rather than derived from a
  # toolchain profile) so pkgsCross can be built *before* the profiles — each
  # profile now consumes pkgsCross to build its first-class cc-wrapper stdenv.
  crossSystem = {
    # Keep nixpkgs parser-compatible triple and pin WASIX tooling explicitly.
    config = "wasm32-unknown-wasi";
    useLLVM = true;
    isWasix = true;
  };
  pkgsCross = import nixpkgs {
    inherit system crossSystem;
    config.allowUnsupportedSystem = true;
  };

  mkToolchainProfile = pkgs.callPackage ./toolchain/mk-profile.nix {
    inherit toolchainPkgs pkgsCross crossSystem;
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
    # No Wasm-EH: setjmp/longjmp and fork() both go through asyncify (used by bash).
    off = mkToolchainProfile {
      name = "off";
      wasmExceptions = "no";
    };
  };
  defaultProfileName = "exnrefEh";
  defaultToolchain = toolchains.${defaultProfileName};

  mkLibraries = toolchain:
    import ./libraries {
      inherit nixpkgs pkgs pkgsCross toolchain;
      includePhp = false;
    };

  # The off (no wasm-EH) profile is not a general library profile: it has no PIC
  # sysroot, so libraries that pull -fPIC in through their own configure/CMake
  # can't link there. It exists only for bash, which links readline+ncurses, so
  # it's kept out of the per-profile library matrix and drawn from on demand.
  libraries = lib.mapAttrs (_: mkLibraries) (removeAttrs toolchains ["off"]);
  offLibraries = mkLibraries toolchains.off;

  defaultLibraries = libraries.${defaultProfileName};

  programs = import ./programs {
    nixpkgs = nixpkgs;
    inherit pkgs pkgsCross;
    toolchain = defaultToolchain;
    # bash + its linked readline/ncurses build off-EH (see ./programs/bash/README.md).
    offToolchain = toolchains.off;
    inherit offLibraries;
    libraries = defaultLibraries;
  };

  makeWasmerPackage = pkgs.callPackage ./wasmer/make-wasmer-package.nix {};
  makePlainWasmerPackage = pkgs.callPackage ./wasmer/make-plain-wasmer-package.nix {};

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
  bashWasmer = pkgs.callPackage ./programs/bash/bashWasmer.nix {
    inherit makeWasmerPackage;
    bash = programs.bash;
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
    inherit pkgs nanoWasmer grepWasmer sedWasmer findWasmer gzipWasmer tarWasmer lessWasmer ncursesWasmer crabsayWasmer curlWasmer bashWasmer gettextWasmer gitWasmer cliPlatformWasmer;
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
in {
  inherit pkgs pkgsCross toolchains libraries programs wasmer allPackages allWasm defaultProfileName;
}
