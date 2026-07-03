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
  };

  outputs = {
    self,
    nixpkgs,
    wasmer,
    treefmt-nix,
    ...
  }: let
    system = "x86_64-linux";
    # wasmer plus PR 6768 (offline resolution: --offline and --include-webc),
    # vendored until it merges. The patch is .rs-only, so cargo deps stay cached.
    wasmerRuntime = wasmer.packages.${system}.wasmer.overrideAttrs (old: {
      patches = (old.patches or []) ++ [./patches/wasmer-offline-resolution.patch];
    });
    wasix = import ./pkgs {
      inherit system nixpkgs;
      # runs the behavioural passthru.tests on the webc packages.
      inherit wasmerRuntime;
    };
    lib = wasix.pkgs.lib;

    # From-source toolchain (LLVM fork + libc + runtimes + sysroot), see pkgs/toolchain.
    foundation = wasix.foundation;

    treefmtEval = treefmt-nix.lib.evalModule wasix.pkgs {
      projectRootFile = "flake.nix";
      programs.alejandra.enable = true;
    };

    # Collect every package's passthru.tests into the flake checks. Wheels get a
    # "wheel-" prefix (their attr names share the flat check namespace with the
    # shipped packages). tryEval per entry: one attr that throws on eval would
    # otherwise abort the whole `checks` output, so drop it instead.
    collectTestsPrefixed = prefix:
      lib.foldlAttrs (
        acc: name: pkg: let
          entry = builtins.tryEval (lib.optionalAttrs (pkg ? tests) {"${prefix}${name}" = pkg.tests;});
        in
          acc
          // (
            if entry.success
            then entry.value
            else {}
          )
      ) {};
    collectTests = collectTestsPrefixed "";
    flakeChecks =
      collectTests wasix.shippedPackages
      // collectTests wasix.toolchainTestPkgs
      // collectTestsPrefixed "wheel-" wasix.pythonWheels
      // lib.mapAttrs' (p: lib.nameValuePair "abi-${p}") wasix.abiChecks
      // {treefmt = treefmtEval.config.build.check self;};
  in {
    formatter.${system} = treefmtEval.config.build.wrapper;

    # Custom outputs go under legacyPackages: unknown top-level flake outputs
    # make `nix flake check` warn.
    legacyPackages.${system} = let
      # These attr paths are both the `.#` build targets and, flattened to dotted
      # keys, the `ci` job names, so the two cannot drift, e.g.
      #   nix build .#foundation.llvm.clang  <->  ci."foundation.llvm.clang"
      buildable = {
        # The flat, profile-independent compilers (the per-profile stdenv/rustPlatform
        # build envs live under the non-buildable `.#toolchain.<profile>`).
        foundation = {
          # sysroot + wasixcc carry their link/stdenv/sysroot suites as passthru.tests.
          inherit (wasix.toolchainTestPkgs) sysroot wasixcc;

          cargo-wasix = foundation.cargoWasix;
          rust-toolchain = foundation.wasixRustToolchain;
          libc = foundation.libc;
          compiler-rt = foundation.compiler-rt;
          libcxx = foundation.libcxx;
          llvm = {inherit (foundation.llvm) clang lld;};
          runtime = wasmerRuntime; # the wasmer runtime (input, patched)
        };
        libraryMatrix = wasix.libraryMatrix; # <profile>.<lib>
        # <name> = wasm cross build; .webc = its webc package; .tests = its tests
        shippedPackages = wasix.shippedPackages;
        # <attr> = wasm cross build of python3.pkgs.<attr>; .tests = import smoke-test
        pythonWheels = wasix.pythonWheels;
      };

      # Flatten nested attrsets of derivations to {"a.b.c" = drv;}: recurse
      # through plain attrsets, stop at a drv, but also emit a shipped package's
      # passthru.webc as "<key>.webc".
      #
      # nix-eval-jobs reports any leaf that throws or is meta.broken (fd/tokei,
      # via passthru.wasix.broken) as a failed job, so drop such leaves here.
      # Only `ci` filters; the `.#` build targets keep the attrs. Unsupported-
      # profile leaves are already filtered out of libraryMatrix in pkgs/default.nix.
      drvOk = drv: (builtins.tryEval (drv.drvPath != null && !(drv.meta.broken or false) && (drv.meta.available or true))).value;
      flattenDrvs = prefix:
        lib.concatMapAttrs (
          name: val: let
            key =
              if prefix == ""
              then name
              else "${prefix}.${name}";
            # Force val behind tryEval first: a throwing attr (broken access)
            # must not abort the whole CI eval before drvOk can filter it.
            forced = builtins.tryEval (lib.seq val val);
          in
            if !forced.success
            then {}
            else if lib.isDerivation val
            then
              lib.optionalAttrs (drvOk val) {${key} = val;}
              // lib.optionalAttrs (val ? webc && drvOk val.webc) {"${key}.webc" = val.webc;}
            else if lib.isAttrs val
            then flattenDrvs key val
            else {}
        );
    in
      buildable
      // {
        # Escape hatches / aggregates: reachable via `.#`, but not ci jobs.
        # `.#toolchain.<profile>.{stdenv,rustPlatform}` is the per-profile build env.
        inherit (wasix) profileSets toolchain defaultProfileName;
        pkgsCross.wasix = wasix.pkgsCross;
        allWasmer = wasix.allWasmer;
        allWasm = wasix.allWasm;

        # One derivation per dotted key for nix-eval-jobs / nix-fast-build; names
        # mirror the `.#` paths above, plus checks.<name> from the flake checks.
        ci = flattenDrvs "" buildable // flattenDrvs "checks" flakeChecks;
      };

    devShells.${system}.default = wasix.pkgs.mkShell {
      packages = [
        foundation.wasixcc
        foundation.cargoWasix
        wasix.profileSets.${wasix.defaultProfileName}.ncurses
        wasix.pkgs.gnumake
        wasix.pkgs.pkg-config
        wasmerRuntime

        nixpkgs.legacyPackages.${system}.nix-fast-build
        nixpkgs.legacyPackages.${system}.nix-eval-jobs
      ];
      shellHook = ''
        ${wasix.toolchain.${wasix.defaultProfileName}.toolchainEnv}
        ${wasix.toolchain.${wasix.defaultProfileName}.ccEnv}
        echo "WASIX shell ready. Build with: nix build"
      '';
    };

    checks.${system} = flakeChecks;

    packages.${system} = {
      # The toolchain + foundation, buildable directly (the webc packages and
      # the merged registry live under legacyPackages).
      wasixcc = foundation.wasixcc;
      cargo-wasix = foundation.cargoWasix;
      wasix-rust-toolchain = foundation.wasixRustToolchain;
      default = foundation.wasixcc;

      # From-source toolchain foundation, buildable in isolation:
      #   nix build .#wasix-libc    (fast)
      #   nix build .#wasix-llvm    (from-source LLVM, slow)
      wasix-libc = foundation.libc;
      wasix-llvm = foundation.llvm.clang;
      # Runtimes built upstream-style (direct cmake of llvm-project driven by
      # wasix-libc's committed clang-wasix*.cmake_toolchain files):
      wasix-compiler-rt = foundation.compiler-rt;
      wasix-libcxx = foundation.libcxx;
      # The assembled multi-variant sysroot:
      wasix-sysroot = foundation.sysroot;
      # (per-variant sysroot smoke tests are checks.wasix-sysroot-<variant>)

      wasmer-bin = wasmerRuntime;
    };

    # `nix run .#update`: bump the source pins of the repo's own packages (not
    # the prev.X nixpkgs passthroughs) and regenerate derived files: cargo
    # regenerates cargo-wasix's Cargo.lock, nix-prefetch-git hashes the rust
    # fork's fetchSubmodules tree (src/llvm-project). Per-package backends live
    # in scripts/update.py.
    apps.${system}.update = {
      type = "app";
      program = lib.getExe (wasix.pkgs.writeShellApplication {
        name = "wasinix-update";
        runtimeInputs = [
          wasix.pkgs.python3
          wasix.pkgs.nix-update
          wasix.pkgs.nix-prefetch-git
          wasix.pkgs.cargo
          wasix.pkgs.git
        ];
        text = ''exec python3 "$(git rev-parse --show-toplevel)/scripts/update.py" "$@"'';
      });
    };
  };
}
