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
    wasmerRuntime = wasmer.packages.${system}.wasmer.overrideAttrs (old: {
      patches =
        (old.patches or [])
        ++ [
          ./patches/wasmer-offline-resolution.patch
          ./patches/wasmer-webc-follow-symlinks.patch
        ];
    });
    wasix = import ./pkgs {
      inherit system nixpkgs;
      # runs the behavioural passthru.tests on the webc packages.
      inherit wasmerRuntime;
    };
    lib = wasix.pkgs.lib;
    wasixLib = import ./pkgs/lib {inherit lib;};

    # From-source toolchain (LLVM fork + libc + runtimes + sysroot), see pkgs/toolchain.
    toolchain = wasix.toolchain;

    treefmtEval = treefmt-nix.lib.evalModule wasix.pkgs {
      projectRootFile = "flake.nix";
      programs = {
        alejandra.enable = true; # nix
        ruff-format.enable = true; # python
        shfmt = {
          enable = true;
          indent_size = 2;
        };
        taplo.enable = true; # toml
        clang-format.enable = true; # c/c++ (.clang-format pins the style)
        # js + yaml + markdown
        # json stays out, as the only json in this repo is machine-generated
        prettier = {
          enable = true;
          includes = ["*.js" "*.yml" "*.yaml" "*.md"];
        };
      };
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
      collectTests wasix.wasmerPackages
      // collectTests wasix.toolchainTestPkgs
      // collectTestsPrefixed "wheel-" wasix.pythonWheels
      // collectTests {python-registry = wasix.pythonRegistry;}
      // lib.mapAttrs' (p: lib.nameValuePair "abi-${p}") wasix.abiChecks
      // {treefmt = treefmtEval.config.build.check self;};
  in {
    formatter.${system} = treefmtEval.config.build.wrapper;

    # Custom outputs go under legacyPackages: unknown top-level flake outputs
    # make `nix flake check` warn.
    legacyPackages.${system} = let
      # These attr paths are both the `.#` build targets and, flattened to dotted
      # keys, the `ci` job names, so the two cannot drift, e.g.
      #   nix build .#toolchain.llvm.clang  <->  ci."toolchain.llvm.clang"
      buildable = {
        # The flat, profile-independent compilers (the per-profile stdenv/rustPlatform
        # build envs live under the non-buildable `.#toolchainByProfile.<profile>`).
        toolchain = {
          # sysroot + wasixcc carry their link/stdenv/sysroot suites as passthru.tests.
          inherit (wasix.toolchainTestPkgs) sysroot wasixcc;

          cargo-wasix = toolchain.cargoWasix;
          rust-toolchain = toolchain.wasixRustToolchain;
          libc = toolchain.libc;
          compiler-rt = toolchain.compiler-rt;
          libcxx = toolchain.libcxx;
          llvm = {inherit (toolchain.llvm) clang lld;};
          runtime = wasmerRuntime; # the wasmer runtime (input, patched)
        };
        librariesByProfile = wasix.librariesByProfile; # <profile>.<lib>
        # <name> = wasm cross build; .pkg = its wasmer package; .webc = the built webc; .tests = its tests
        wasmerPackages = wasix.wasmerPackages;
        # <attr> = wasm cross build of python3.pkgs.<attr>; .tests = import smoke-test
        pythonWheels = wasix.pythonWheels;
        # all shipped wheels + transitive deps as a static PEP 503 index
        pythonRegistry = wasix.pythonRegistry;
      };

      # Flatten nested attrsets of derivations to {"a.b.c" = drv;}: recurse
      # through plain attrsets, stop at a drv, but also emit a shipped package's
      # passthru.webc as "<key>.webc".
      #
      # nix-eval-jobs reports any leaf that throws or is meta.broken (fd/tokei,
      # via passthru.wasix.broken) as a failed job, so drop such leaves here.
      # Only `ci` filters; the `.#` build targets keep the attrs. Unsupported-
      # profile leaves are already filtered out of librariesByProfile in pkgs/default.nix.
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
      # One derivation per dotted key for nix-eval-jobs / nix-fast-build; names
      # mirror the `.#` paths above, plus checks.<name> from the flake checks.
      ci = flattenDrvs "" buildable // flattenDrvs "checks" flakeChecks;
    in
      buildable
      // {
        # Escape hatches / aggregates: reachable via `.#`, but not ci jobs.
        # `.#toolchainByProfile.<profile>.{stdenv,rustPlatform}` is the per-profile build env.
        inherit (wasix) nixpkgsByProfile toolchainByProfile defaultProfileName;
        pkgsCross.wasix = wasix.pkgsCross;
        allWasmerPackages = wasix.allWasmerPackages;
        allWasm = wasix.allWasm;

        inherit ci;

        # CI shell steps as runnable apps with nix-pinned deps: `nix run
        # .#scripts.<name>`. The script is store-copied, so this needs no git
        # checkout (the remote CI builder runs ci-build over the store-copied
        # flake source); a script's data and sibling paths resolve against the
        # caller's CWD, which in CI is the checkout root. Only the deps come
        # from nix. The local-dev remote-builder scripts are $0-relative and
        # stay out.
        scripts = let
          p = wasix.pkgs;
          run = name: runtimeInputs: interp: file:
            p.writeShellApplication {
              inherit name;
              runtimeInputs = runtimeInputs ++ [p.git];
              text = ''exec ${interp} ${file} "$@"'';
            };
        in {
          ci-build = run "ci-build" [p.jq p.nix-eval-jobs p.nix-fast-build] "bash" ./scripts/ci-build.sh;
          rebuild-diff = run "rebuild-diff" [p.python3] "bash" ./scripts/rebuild-diff.sh;
          content-diff = run "content-diff" [p.python3] "python3" ./scripts/content-diff.py;
          ci-report = run "ci-report" [p.python3] "python3" ./scripts/ci-report.py;
          publish-eval-map = run "publish-eval-map" [p.awscli2] "bash" ./scripts/publish-eval-map.sh;
          bump-rel = run "bump-rel" [p.python3] "python3" ./pkgs/python-registry/bump-rel.py;
          publish = run "publish" [wasmerRuntime p.rclone p.python3] "bash" ./scripts/publish.sh;
        };

        # passthru.wasix.updateNotes (see pkgs/lib/default.nix): things to
        # check when a package moves. `versions` is published in the eval
        # maps; `fired` gets the base branch's copy of it back as the `prior`
        # side of each note's predicate. Read by scripts/update.py and the CI
        # report; consumers dedupe the per-profile repeats.
        updateNotes = let
          noted = lib.filterAttrs (_: wasixLib.hasUpdateNotes) ci;
          versionOf = drv: let
            r = builtins.tryEval (drv.version or null);
          in
            if r.success
            then r.value
            else null;
        in {
          versions = lib.mapAttrs (_: versionOf) noted;
          fired = priors:
            lib.filterAttrs (_: ns: ns != [])
            (lib.mapAttrs (attr: wasixLib.firedNotesOf (priors.${attr} or null)) noted);
        };

        # passthru.updateScript declarations (standard nixpkgs convention),
        # collected for scripts/update.py: the command, an optional display
        # name, and meta.position (the file the pin lives in; the overlay
        # loader stamps it to our files). Consumers dedupe per-profile repeats.
        updateScripts = let
          srcRoot = toString self;
          scriptOf = attr: drv: let
            s = drv.passthru.updateScript or null;
            command =
              if lib.isList s
              then map toString s
              else if lib.isAttrs s && s ? command
              then map toString (lib.toList s.command)
              else null;
            # prev.X packages inherit nixpkgs' updateScripts, which must not
            # run against this repo; ours are the ones declared in this tree
            pos = builtins.unsafeGetAttrPos "updateScript" (drv.passthru or {});
            ours =
              command
              != null
              && command != []
              && pos != null
              && lib.hasPrefix srcRoot pos.file;
            entry = builtins.tryEval (
              let
                v = lib.optionalAttrs ours {
                  ${attr} =
                    {inherit command;}
                    // lib.optionalAttrs (lib.isAttrs s && s ? name) {inherit (s) name;}
                    // lib.optionalAttrs (lib.isAttrs s && s ? attrPath) {inherit (s) attrPath;}
                    // {position = drv.meta.position or null;};
                };
              in
                builtins.deepSeq v v
            );
          in
            if entry.success
            then entry.value
            else {};
        in
          lib.concatMapAttrs scriptOf ci;
      };

    devShells.${system}.default = wasix.pkgs.mkShell {
      packages = [
        toolchain.wasixcc
        toolchain.cargoWasix
        wasix.nixpkgsByProfile.${wasix.defaultProfileName}.ncurses
        wasix.pkgs.gnumake
        wasix.pkgs.pkg-config
        wasmerRuntime

        nixpkgs.legacyPackages.${system}.nix-fast-build
        nixpkgs.legacyPackages.${system}.nix-eval-jobs
      ];
      shellHook = ''
        ${wasix.toolchainByProfile.${wasix.defaultProfileName}.toolchainEnv}
        ${wasix.toolchainByProfile.${wasix.defaultProfileName}.ccEnv}
        echo "WASIX shell ready. Build with: nix build"
      '';
    };

    checks.${system} = flakeChecks;

    packages.${system} = {
      # The toolchain, buildable directly (the webc packages and
      # the merged registry live under legacyPackages).
      wasixcc = toolchain.wasixcc;
      cargo-wasix = toolchain.cargoWasix;
      wasix-rust-toolchain = toolchain.wasixRustToolchain;
      default = toolchain.wasixcc;

      # From-source toolchain parts, buildable in isolation:
      #   nix build .#wasix-libc    (fast)
      #   nix build .#wasix-llvm    (from-source LLVM, slow)
      wasix-libc = toolchain.libc;
      wasix-llvm = toolchain.llvm.clang;
      # Runtimes built upstream-style (direct cmake of llvm-project driven by
      # wasix-libc's committed clang-wasix*.cmake_toolchain files):
      wasix-compiler-rt = toolchain.compiler-rt;
      wasix-libcxx = toolchain.libcxx;
      # The assembled multi-variant sysroot:
      wasix-sysroot = toolchain.sysroot;
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
