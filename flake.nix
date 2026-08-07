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
    ghc-wasm-meta = {
      url = "gitlab:haskell-wasm/ghc-wasm-meta?host=gitlab.haskell.org";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    self,
    nixpkgs,
    wasmer,
    treefmt-nix,
    ghc-wasm-meta,
    ...
  }: let
    system = "x86_64-linux";
    wasmerPatches = [
      # proc_fork must inherit the parent's signal dispositions; see WASIX-TODO.md
      ./patches/wasmer-signal-inherit-on-fork.patch
      # futex_wake dropped a wake when the first waiter was still
      # mid-registration (Some(None)), starving a genuinely-sleeping waiter;
      # deadlocked tokio multi-thread spawn+blocking (e.g. rustfs server).
      ./patches/wasmer-futex-wake-lost-wakeup.patch
      # fd_datasync/fd_sync denied with EACCES when path_open's rights
      # delegation masked the implied FD_DATASYNC/FD_SYNC off files under
      # mapped host dirs; rustfs object writes (fdatasync durability) 500'd.
      ./patches/wasmer-fd-sync-rights-durability.patch
      # Host hard links and their rename/unlink cache entries are broken.
      ./patches/wasmer-path-rename-hardlink.patch
      # fd_readdir cookies must remain valid while callers delete entries.
      ./patches/wasmer-fd-readdir-stable-cookie.patch
    ];
    wasmerRuntime = wasmer.packages.${system}.wasmer.overrideAttrs (old: {
      patches = (old.patches or []) ++ wasmerPatches;
      # The inherited artifact contains unpatched workspace crates and can
      # retain their rlibs and vtables after source patches are applied.
      cargoArtifacts = null;
      passthru =
        (old.passthru or {})
        // {
          wasix = {
            # upstream's version stands still across our rev bumps
            noteVersion = "${old.version}-${wasmer.shortRev or "dirty"}";
            updateNotes = [
              {message = "recheck and drop any Wasmer patches that landed upstream; see WASIX-TODO.md";}
            ];
          };
        };
    });
    # spotOverlays is empty everywhere but spot.nix; see pkgs/spot.nix.
    mkWasix = spotOverlays:
      import ./pkgs {
        inherit system nixpkgs spotOverlays;
        # runs the behavioural passthru.tests on the webc packages.
        inherit wasmerRuntime;
        # bindist GHC for toolchain.haskell; overlay/packages/pandoc builds against it
        ghcWasm = ghc-wasm-meta.packages.${system};
      };
    wasix = mkWasix {};
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
        # json stays out, as the only json in this repo is machine-generated
        prettier = {
          enable = true;
          includes = ["*.js" "*.yml" "*.yaml" "*.md"];
        };
      };
    };

    # Collect every package's passthru.tests into the flake checks. tryEval guards
    # the `pkg ? tests` probe, which forces pkg; a throwing pkg keeps its entry, so
    # the error surfaces as a failed check instead of aborting the whole output.
    collectTestsPrefixed = prefix:
      lib.foldlAttrs (
        acc: name: pkg: let
          testAttr = {"${prefix}${name}" = pkg.tests;};
          entry = builtins.tryEval (lib.optionalAttrs (pkg ? tests) testAttr);
        in
          acc
          // (
            if entry.success
            then entry.value
            else testAttr
          )
      ) {};
    collectTests = collectTestsPrefixed "";
    flakeChecks =
      collectTests wasix.wasmerPackages
      // collectTests wasix.toolchainTestPkgs
      # pythonWheels is nested by version (py313/py314); collect as wheel-py314-<attr>.
      // lib.concatMapAttrs (pv: wheelSet: collectTestsPrefixed "wheel-${pv}-" wheelSet) wasix.pythonWheels
      // collectTests {python-registry = wasix.pythonRegistry;}
      // collectTests {cargo-registry = wasix.cargoRegistry;}
      // lib.mapAttrs' (p: lib.nameValuePair "abi-${p}") wasix.abiChecks
      # non-shipped library packages carrying a tests/ dir
      // collectTests wasix.libraryTestPkgs
      // {treefmt = treefmtEval.config.build.check self;};
  in {
    formatter.${system} = treefmtEval.config.build.wrapper;

    # Custom outputs go under legacyPackages: unknown top-level flake outputs
    # make `nix flake check` warn.
    legacyPackages.${system} = let
      # These attr paths are both the `.#` build targets and, flattened to dotted
      # keys, the `ci` job names, so the two cannot drift.
      buildable = {
        # Profile-independent tools. Sysroot libraries and their Fortran/OpenMP
        # drivers live under `.#toolchainByProfile.<profile>`.
        toolchain = {
          # These carry their test suites as passthru.tests.
          inherit (wasix.toolchainTestPkgs) sysroot wasixcc;

          anybuild = toolchain.anybuild;
          cargo-wasix = toolchain.cargoWasix;
          rust-toolchain = toolchain.wasixRustToolchain;
          libc = toolchain.libc;
          compiler-rt = toolchain.compiler-rt;
          libcxx = toolchain.libcxx;
          llvm = {inherit (toolchain.llvm) clang lld;};
          flang = toolchain.flang; # host Fortran->wasm compiler (wasm32 target patch)
          runtime = wasmerRuntime; # the wasmer runtime (input, patched)
        };
        librariesByProfile = wasix.librariesByProfile; # <profile>.<lib>
        # Shared Wasmer/WASIX product recipes built for the native host. The
        # WASIX profile matrix is available through the packagesByHost escape
        # hatch below and is already covered by the product-oriented outputs.
        nativePackages = wasix.nativePackages;
        # <name> = wasm cross build; .pkg = its wasmer package; .webc = the built webc; .tests = its tests
        wasmerPackages = wasix.wasmerPackages;
        # <attr> = wasm cross build of python3.pkgs.<attr>; .tests = import smoke-test
        pythonWheels = wasix.pythonWheels;
        # all shipped wheels + transitive deps as a static PEP 503 index
        pythonRegistry = wasix.pythonRegistry;
        # the crate patch tree minted as publishable +wasix.N fork builds
        cargoRegistry = wasix.cargoRegistry;
      };

      # Flatten nested attrsets of derivations to {"a.b.c" = drv;}, also emitting a
      # shipped package's passthru.webc as "<key>.webc". Only meta is read, never
      # drvPath: every nix-eval-jobs worker computes the key set before its first
      # job. A throwing leaf is KEPT, so it surfaces as one failed job.
      drvOk = drv: let
        r = builtins.tryEval (!(drv.meta.broken or false) && (drv.meta.available or true));
      in
        !r.success || r.value;
      flattenDrvs = prefix:
        lib.concatMapAttrs (
          name: val: let
            key =
              if prefix == ""
              then name
              else "${prefix}.${name}";
            # forcing val to classify it can throw; keep the leaf under its key
            kind = builtins.tryEval (
              if lib.isDerivation val
              then "drv"
              else if lib.isAttrs val
              then "set"
              else "other"
            );
          in
            if !kind.success
            then {${key} = val;}
            else if kind.value == "drv"
            then
              lib.optionalAttrs (drvOk val) {${key} = val;}
              // lib.optionalAttrs (val ? webc && drvOk val.webc) {"${key}.webc" = val.webc;}
            else if kind.value == "set"
            then flattenDrvs key val
            else {}
        );
      # One derivation per dotted key for nix-eval-jobs / nix-fast-build.
      # toolchain.anybuild remains a compatibility alias for the native
      # product; nativePackages.anybuild is its single CI job.
      ciBuildable = buildable // {toolchain = removeAttrs buildable.toolchain ["anybuild"];};
      ci = flattenDrvs "" ciBuildable // flattenDrvs "checks" flakeChecks;
    in
      buildable
      // {
        # Escape hatches / aggregates: reachable via `.#`, but not ci jobs.
        inherit (wasix) nixpkgsByProfile toolchainByProfile defaultProfileName;
        inherit (wasix) packagesByHost toolchains;

        # Rebuild one target against the working tree with everything below it
        # pinned to a pristine base (./spot.nix). A function, so never a ci job.
        spotWith = import ./pkgs/spot.nix {
          inherit lib mkWasix;
          pkgNames = wasix.wasixPkgNames;
        };
        pkgsCross.wasix = wasix.pkgsCross;
        allWasmerPackages = wasix.allWasmerPackages;

        inherit ci;

        # CI shell steps as runnable apps with nix-pinned deps: `nix run
        # .#scripts.<name>`. The dir is store-copied, so no git checkout is needed
        # and a script imports its siblings from the same copy; DATA paths still
        # resolve against the caller's CWD.
        scripts = let
          p = wasix.pkgs;
          # the whole dir, not the single file: cheap, they only write a shell stub
          dir = ./scripts;
          # inheritPath = false: PATH is exactly the declared deps, so a script
          # reaching for an undeclared tool fails loudly. Per-script lists are extras.
          run = name: runtimeInputs: interp: file:
            p.writeShellApplication {
              inherit name;
              inheritPath = false;
              runtimeInputs =
                runtimeInputs
                ++ [p.git p.coreutils p.nixVersions.latest]
                ++ [
                  (
                    if interp == "python3"
                    then p.python3
                    else p.bash
                  )
                ];
              text = ''
                ${
                  # CI log capture block-buffers python stdout, hiding progress until exit
                  lib.optionalString (interp == "python3") "export PYTHONUNBUFFERED=1"
                }
                exec ${interp} ${dir}/${file} "$@"
              '';
            };
        in {
          ci-build = run "ci-build" [p.jq p.nix-eval-jobs p.nix-fast-build p.findutils] "bash" "ci-build.sh";
          rebuild-diff = run "rebuild-diff" [p.python3 p.nix-eval-jobs] "bash" "rebuild-diff.sh";
          content-diff = run "content-diff" [] "python3" "content-diff.py";
          ci-report = run "ci-report" [] "python3" "ci-report.py";
          publish-eval-map = run "publish-eval-map" [p.awscli2] "bash" "publish-eval-map.sh";
          bump-rel = run "bump-rel" [] "python3" "bump-rel.py";
          publish-index = run "publish-index" [wasmerRuntime p.rclone p.python3 p.gawk p.gnused] "bash" "publish-index.sh";
          publish-webc = run "publish-webc" [wasmerRuntime] "python3" "publish-webc.py";
          history = run "history" [] "python3" "history.py";
          preview-diff = run "preview-diff" [] "python3" "preview-diff.py";
          preview-index-deploy = run "preview-index-deploy" [wasmerRuntime p.jq] "bash" "preview-index-deploy.sh";
          update = run "update" [wasix.nixUpdate p.nix-prefetch-git p.cargo] "python3" "update.py";
          # Runs the wasix server (overlay package) under wasmer, seeded from the
          # fresh mint; cargo relocks/builds against the local instance.
          cargo-registry-serve = run "cargo-registry-serve" [p.nixVersions.latest p.cargo wasmerRuntime] "python3" "cargo-registry-serve.py";
          # Regenerate pkgs/cargo-registry/crates.json: the concrete fork version
          # set (patch versions + supportedVersions constraints enumerated against
          # the crates.io index) and each crate's hash (.#cargoRegistry.pinInputs).
          crate-pins = run "crate-pins" [p.nixVersions.latest] "python3" "crate-pins.py";
        };

        # rels.json key -> served upstream versions. Read by scripts/update.py (prune
        # stale keys) and scripts/bump-rel.py (validate + look up).
        relVersions =
          lib.mapAttrs' (n: v: lib.nameValuePair "pythonRegistry.wheels.${n}" v)
          wasix.pythonRegistry.wheelVersions
          # history versions key wasmerPackages as <name>-<semver> but publish under one name
          // lib.mapAttrs' (name: ps:
            lib.nameValuePair "wasmerPackages.${name}"
            (lib.unique (map (p: p.pkg.id.baseVersion) ps)))
          (lib.groupBy (p: p.pkg.id.name) (lib.attrValues wasix.wasmerPackages))
          # minted forks key by upstream version under cargoRegistry.crates.<name>.
          // lib.mapAttrs' (n: v: lib.nameValuePair "cargoRegistry.crates.${n}" v)
          wasix.cargoRegistry.crateVersions;

        # passthru.wasix.updateNotes: things to check when a package moves.
        # `versions` is published in the eval maps; `fired` gets the base branch's
        # copy back as the `prior` side of each note's predicate.
        updateNotes = let
          noted = lib.filterAttrs (_: wasixLib.hasUpdateNotes) ci;
          versionOf = drv: let
            r = builtins.tryEval (wasixLib.noteVersionOf drv);
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

        # passthru.updateScript declarations collected for scripts/update.py, with
        # meta.position (the file the pin lives in).
        updateScripts = let
          srcRoot = toString self;
          scriptOf = attr: drv: let
            s = drv.passthru.updateScript or null;
            commandValues =
              if lib.isList s
              then s
              else if lib.isAttrs s && s ? command
              then lib.toList s.command
              else null;
            command =
              if commandValues == null
              then null
              else map toString commandValues;
            commandDrvPaths =
              if commandValues == null
              then null
              else if lib.isAttrs s && s ? commandDrvPaths
              then
                map (v:
                  if lib.isDerivation v
                  then v.drvPath
                  else toString v)
                (lib.toList s.commandDrvPaths)
              else
                map (v:
                  if lib.isDerivation v
                  then v.drvPath
                  else null)
                commandValues;
            # prev.X packages inherit nixpkgs' updateScripts, which must not
            # run against this repo; ours are the ones declared in this tree.
            # Registry-history attrs (numpy_2_1_3) re-import the package file, so
            # they inherit its in-tree updateScript too; exclude them, else
            # nix-update would bump a version pinned on purpose.
            pos = builtins.unsafeGetAttrPos "updateScript" (drv.passthru or {});
            ours =
              command
              != null
              && command != []
              && pos != null
              && lib.hasPrefix srcRoot pos.file
              && !(drv.passthru.wasmer.history or false);
            entry = builtins.tryEval (
              let
                v = lib.optionalAttrs ours {
                  ${attr} =
                    {
                      inherit command commandDrvPaths;
                      version = drv.version or null;
                    }
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

        # passthru.wasix.retentionHook: a command scripts/update.py runs after the
        # repo-wide history/prune steps. In-tree only; the driver dedupes repeats.
        retentionHooks = let
          srcRoot = toString self;
          hookOf = attr: drv: let
            h = (drv.passthru.wasix or {}).retentionHook or null;
            command =
              if h == null
              then null
              else map toString (lib.toList h);
            pos = builtins.unsafeGetAttrPos "wasix" (drv.passthru or {});
            ours =
              command
              != null
              && command != []
              && pos != null
              && lib.hasPrefix srcRoot pos.file;
            entry = builtins.tryEval (
              let
                v = lib.optionalAttrs ours {${attr} = {inherit command;};};
              in
                builtins.deepSeq v v
            );
          in
            if entry.success
            then entry.value
            else {};
        in
          lib.concatMapAttrs hookOf ci;
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
        nixpkgs.legacyPackages.${system}.nixVersions.latest
      ];
      shellHook = ''
        ${wasix.toolchainByProfile.${wasix.defaultProfileName}.toolchainEnv}
        ${wasix.toolchainByProfile.${wasix.defaultProfileName}.ccEnv}
      '';
    };

    checks.${system} = flakeChecks;

    packages.${system} = {
      # the webc packages and the merged registry live under legacyPackages
      anybuild = toolchain.anybuild;
      wasixcc = toolchain.wasixcc;
      cargo-wasix = toolchain.cargoWasix;
      wasix-rust-toolchain = toolchain.wasixRustToolchain;
      default = toolchain.wasixcc;

      # From-source toolchain parts, buildable in isolation.
      wasix-libc = toolchain.libc;
      wasix-llvm = toolchain.llvm.clang;
      # direct cmake of llvm-project, driven by wasix-libc's clang-wasix*.cmake_toolchain
      wasix-compiler-rt = toolchain.compiler-rt;
      wasix-libcxx = toolchain.libcxx;
      wasix-sysroot = toolchain.sysroot;

      wasmer-bin = wasmerRuntime;
    };
  };
}
