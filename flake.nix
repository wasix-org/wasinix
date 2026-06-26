{
  description = "WASIX package repository";

  nixConfig = {
    extra-substituters = ["https://nix-cache.wasix.org"];
    extra-trusted-public-keys = ["wasinix-1:jvsqbOJGsZxMvg97fuyNCWCc+t2nn6uHB47kQCGNmXI="];
  };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    wasmer = {
      url = "git+https://github.com/wasmerio/wasmer";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # self.submodules = true;
  };

  outputs = {
    self,
    nixpkgs,
    wasmer,
    treefmt-nix,
    ...
  }: let
    system = "x86_64-linux";
    wasix = import ./pkgs {
      inherit system nixpkgs;
      # used to run the behavioural passthru.tests on the webc packages.
      wasmerRuntime = wasmer.packages.${system}.wasmer;
    };
    lib = wasix.pkgs.lib;

    # The from-source toolchain foundation (LLVM fork + libc + runtimes + sysroot,
    # built the upstream way) lives in pkgs/toolchain and is exposed via
    # wasix.toolchainPkgs.
    toolchainPkgs = wasix.toolchainPkgs;

    treefmtEval = treefmt-nix.lib.evalModule wasix.pkgs {
      projectRootFile = "flake.nix";
      programs.alejandra.enable = true;
    };

    # nix flake check input: every package's passthru.tests — the behavioural
    # suites on the shipped packages AND the link/stdenv/sysroot suites on the
    # toolchain packages, all attached in pkgs/ — collected uniformly, + treefmt.
    collectTests = lib.foldlAttrs (acc: name: pkg: acc // lib.optionalAttrs (pkg ? tests) {${name} = pkg.tests;}) {};
    flakeChecks =
      collectTests wasix.shippedPackages
      // collectTests wasix.toolchainTestPkgs
      // {treefmt = treefmtEval.config.build.check self;};
  in {
    formatter.${system} = treefmtEval.config.build.wrapper;

    # Custom outputs live here because the flake-output schema only recognises
    # packages/checks/devShells/… — anything else at top level makes `nix flake
    # check` warn. legacyPackages is the unchecked escape hatch.
    legacyPackages.${system} = let
      defaultToolchain = wasix.toolchains.${wasix.defaultProfileName};

      # ── canonical buildable trees ─────────────────────────────────────────────
      # These attr paths ARE the `.#` build targets, and (flattened to dotted
      # keys) the `ci` job names — so the two cannot drift. e.g.
      #   nix build .#libraryMatrix.exnrefEh.ncurses   <->   ci."libraryMatrix.exnrefEh.ncurses"
      #   nix build .#toolchain.llvm.clang             <->   ci."toolchain.llvm.clang"
      toolchain = {
        # sysroot + wasixcc carry their suites as passthru.tests (link/stdenv/
        # sysroot), so .#toolchain.sysroot.tests / .wasixcc.tests work.
        inherit (wasix.toolchainTestPkgs) sysroot wasixcc;
        cargo-wasix = defaultToolchain.cargoWasix;
        libc = toolchainPkgs.libc;
        compiler-rt = toolchainPkgs.compiler-rt;
        libcxx = toolchainPkgs.libcxx;
        llvm = {inherit (toolchainPkgs.llvm) clang lld;};
        runtime = wasmer.packages.${system}.wasmer; # the wasmer runtime (input)
      };
      buildable = {
        inherit toolchain;
        libraryMatrix = wasix.libraryMatrix; # <profile>.<lib>
        # <name> = wasm cross build; .webc = its webc package; .tests = its tests
        shippedPackages = wasix.shippedPackages;
      };

      # Flatten nested attrsets of derivations to {"a.b.c" = drv;} — the dotted
      # key is the attr path. Recurse through plain attrsets, stop at a drv (but
      # still emit a shipped package's passthru.webc, so shippedPackages.git.webc
      # is its own job / build path).
      flattenDrvs = prefix:
        lib.concatMapAttrs (
          name: val: let
            key =
              if prefix == ""
              then name
              else "${prefix}.${name}";
          in
            if lib.isDerivation val
            then {${key} = val;} // lib.optionalAttrs (val ? webc) {"${key}.webc" = val.webc;}
            else if lib.isAttrs val
            then flattenDrvs key val
            else {}
        );
    in
      buildable
      // {
        # escape hatches / aggregates — reachable via `.#`, but not ci jobs.
        inherit (wasix) profileSets toolchains defaultProfileName;
        pkgsCross.wasix = wasix.pkgsCross;
        allWasmer = wasix.allWasmer;
        allWasm = wasix.allWasm;

        # One derivation per dotted key for nix-eval-jobs / nix-fast-build; names
        # mirror the `.#` paths above, plus checks.<name> from the flake checks.
        ci = flattenDrvs "" buildable // flattenDrvs "checks" flakeChecks;
      };

    devShells.${system}.default = wasix.pkgs.mkShell {
      packages = [
        wasix.toolchains.${wasix.defaultProfileName}.wasixcc
        wasix.toolchains.${wasix.defaultProfileName}.cargoWasix
        wasix.profileSets.${wasix.defaultProfileName}.ncurses
        wasix.pkgs.gnumake
        wasix.pkgs.pkg-config
        wasmer.packages.${system}.wasmer

        nixpkgs.legacyPackages.${system}.nix-fast-build
        nixpkgs.legacyPackages.${system}.nix-eval-jobs
      ];
      shellHook = ''
        ${wasix.toolchains.${wasix.defaultProfileName}.toolchainEnv}
        ${wasix.toolchains.${wasix.defaultProfileName}.ccEnv}
        echo "WASIX shell ready. Build with: nix build"
      '';
    };

    checks.${system} = flakeChecks;

    packages.${system} = {
      # The toolchain + foundation, buildable directly. (The webc packages and
      # the merged registry live under legacyPackages — see above.)
      wasixcc = wasix.toolchains.${wasix.defaultProfileName}.wasixcc;
      cargo-wasix = wasix.toolchains.${wasix.defaultProfileName}.cargoWasix;
      default = wasix.toolchains.${wasix.defaultProfileName}.wasixcc;

      # From-source toolchain foundation, buildable in isolation:
      #   nix build .#wasix-libc    (fast)
      #   nix build .#wasix-llvm    (from-source LLVM — slow)
      wasix-libc = toolchainPkgs.libc;
      wasix-llvm = toolchainPkgs.llvm.clang;
      # Runtimes built upstream-style (direct cmake of llvm-project driven by
      # wasix-libc's committed clang-wasix*.cmake_toolchain files):
      wasix-compiler-rt = toolchainPkgs.compiler-rt;
      wasix-libcxx = toolchainPkgs.libcxx;
      # The assembled multi-variant sysroot:
      wasix-sysroot = toolchainPkgs.sysroot;
      # (per-variant sysroot smoke tests are checks.wasix-sysroot-<variant>)

      wasmer-bin = wasmer.packages.${system}.wasmer;
    };
  };
}
