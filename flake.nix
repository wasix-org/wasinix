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
      # fd_filestat_get served a cached size that a rename left too large, so a
      # read_exact sized from it hit UnexpectedEof; rustfs failed to delete an
      # object whose metadata it had rewritten smaller.
      ./patches/wasmer-fd-filestat-stale-size.patch
      # isatty must be false for redirected stdio; see WASIX-TODO.md
      ./patches/wasmer-isatty-non-tty-unknown.patch
      # terminal programs need TERM; see WASIX-TODO.md
      ./patches/wasmer-forward-term-on-tty.patch
      # /dev/fd/<n> is the caller's fd n, which bash needs for <(...); see WASIX-TODO.md
      ./patches/wasmer-dev-fd.patch
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
      # Captured tool output, compared byte for byte by the tests.
      settings.global.excludes = ["tools/wasinix/fixtures/golden/*"];
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
    testWithOwner = owner: testName: drv:
      drv
      // {
        passthru =
          (drv.passthru or {})
          // {
            wasix =
              (drv.passthru.wasix or {})
              // {
                ciSubject = owner;
                ciTestName = testName;
              };
          };
      };
    collectTestsPrefixed = prefix:
      lib.foldlAttrs (
        acc: name: pkg: let
          fallback = {"${prefix}${name}" = testWithOwner name "tests" pkg.tests;};
          testAttrs = let
            cases = (pkg.tests.passthru.wasix or {}).testCases or null;
          in
            if cases == null
            then fallback
            else
              lib.mapAttrs'
              (caseName: drv:
                lib.nameValuePair
                "${prefix}${name}-${caseName}"
                (testWithOwner name caseName drv))
              cases;
          entry = builtins.tryEval (lib.optionalAttrs (pkg ? tests) testAttrs);
        in
          acc
          // (
            if entry.success
            then entry.value
            else fallback
          )
      ) {};
    collectTests = collectTestsPrefixed "";
    mergeDisjoint = context: sets: let
      names = lib.concatMap builtins.attrNames sets;
      duplicates =
        lib.attrNames
        (lib.filterAttrs (_: occurrences: lib.length occurrences > 1)
          (lib.groupBy (name: name) names));
    in
      lib.throwIf (duplicates != [])
      "${context}: duplicate jobs (${lib.concatStringsSep ", " duplicates})"
      (lib.foldl' (acc: set: acc // set) {} sets);
    treefmtCheck = treefmtEval.config.build.check self;
    checksBySet = {
      core = mergeDisjoint "checksBySet.core" [
        (collectTests wasix.toolchainTestPkgs)
      ];
      packages = mergeDisjoint "checksBySet.packages" [
        (collectTests (removeAttrs wasix.wasmerPackages ["rust"]))
        (lib.optionalAttrs (wasix.wasmerPackages ? rust) {rust-webc = wasix.wasmerPackages.rust.tests;})
        (collectTests {cargo-registry = wasix.cargoRegistry;})
        (lib.mapAttrs' (p: lib.nameValuePair "abi-${p}") wasix.abiChecks)
        # non-shipped library packages carrying a tests/ dir
        (collectTests wasix.libraryTestPkgs)
      ];
      python = mergeDisjoint "checksBySet.python" [
        # pythonWheels is nested by version; collect as wheel-py314-<attr>.
        (lib.concatMapAttrs (pv: wheelSet: collectTestsPrefixed "wheel-${pv}-" wheelSet) wasix.pythonWheels)
        (collectTests {python-registry = wasix.pythonRegistry;})
      ];
    };
    flakeChecks = mergeDisjoint "checks" ([{treefmt = treefmtCheck;}] ++ builtins.attrValues checksBySet);
  in {
    formatter.${system} = treefmtEval.config.build.wrapper;

    # Custom outputs go under legacyPackages: unknown top-level flake outputs
    # make `nix flake check` warn.
    legacyPackages.${system} = let
      # These attr paths are both the `.#` build targets and, flattened to dotted
      # keys, the CI job names, so the two cannot drift.
      buildable = {
        # Profile-independent tools. Sysroot libraries and their Fortran/OpenMP
        # drivers live under `.#toolchainByProfile.<profile>`.
        toolchain = {
          # These carry their test suites as passthru.tests.
          inherit (wasix.toolchainTestPkgs) sysroot wasixcc;

          cargo-wasix = toolchain.cargoWasix;
          rust-toolchain = toolchain.wasixRustToolchain;
          libc = toolchain.libc;
          compiler-rt = toolchain.compiler-rt;
          libcxx = toolchain.libcxx;
          llvm = {inherit (toolchain.llvm) clang lld;};
          flang = toolchain.flang; # host Fortran->wasm compiler (wasm32 target patch)
          runtime = wasmerRuntime; # the wasmer runtime (input, patched)
        };
        # Every overlay package under every profile it supports. CI replaces
        # this complete view with the package-declared ciProfiles selection.
        packagesByProfile = wasix.packagesByProfile;
        # Shared Wasmer/WASIX product recipes built for the native host.
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
      # Disjoint selection presets. Keep these semantic: core validates the
      # toolchain, packages covers C/C++/Rust programs and libraries, and python
      # owns the wheel/registry matrix. `all` is the explicit full sweep.
      ciSetParts = {
        core = [
          (flattenDrvs "toolchain" buildable.toolchain)
          (flattenDrvs "checks" checksBySet.core)
        ];
        packages = [
          # The package-declared coverage, not every profile a package supports.
          (flattenDrvs "packagesByProfile" wasix.ciPackagesByProfile)
          (flattenDrvs "wasmerPackages" buildable.wasmerPackages)
          (flattenDrvs "nativePackages" buildable.nativePackages)
          (flattenDrvs "" {inherit (buildable) cargoRegistry;})
          (flattenDrvs "checks" checksBySet.packages)
        ];
        python = [
          (flattenDrvs "pythonWheels" buildable.pythonWheels)
          (flattenDrvs "" {inherit (buildable) pythonRegistry;})
          (flattenDrvs "checks" checksBySet.python)
        ];
      };
      ciSetsDisjoint =
        lib.mapAttrs
        (name: mergeDisjoint "ciSets.${name}")
        ciSetParts;
      ciSets =
        ciSetsDisjoint
        // {all = mergeDisjoint "ciSets.all" (builtins.attrValues ciSetsDisjoint);};
      ciJobNames = builtins.attrNames ciSets.all;
      toolchainJobs = lib.filter (lib.hasPrefix "toolchain.") ciJobNames;
      spotLib = import ./pkgs/spot.nix {
        inherit lib mkWasix;
        pkgNames = wasix.wasixPkgNames;
      };
      ciGroups = {
        toolchain = {
          jobs = toolchainJobs;
          spotOwners = spotLib.toolchainNames;
        };
        cc = {
          jobs =
            lib.filter
            (name:
              !(lib.hasPrefix "toolchain.cargo-wasix" name)
              && !(lib.hasPrefix "toolchain.rust-toolchain" name)
              && name != "toolchain.runtime")
            toolchainJobs;
          spotOwners = ["stdenv"];
        };
        rust = {
          jobs =
            lib.filter
            (name:
              lib.hasPrefix "toolchain.cargo-wasix" name
              || lib.hasPrefix "toolchain.rust-toolchain" name)
            toolchainJobs;
          spotOwners = ["rustPlatform"];
        };
        haskell = {
          jobs =
            lib.filter
            (name:
              (lib.hasPrefix "packagesByProfile." name
                || lib.hasPrefix "wasmerPackages." name)
              && lib.hasInfix "pandoc" name)
            ciJobNames;
          spotOwners = ["haskellPackages"];
        };
      };
      spotJobInfo =
        lib.concatMapAttrs
        (profile: packages:
          lib.mapAttrs'
          (name: _:
            lib.nameValuePair "packagesByProfile.${profile}.${name}" {
              spotTarget = "${profile}.${name}";
              spotOwner = name;
            })
          packages)
        wasix.ciPackagesByProfile;
      ciJobInfo = lib.mapAttrs (name: drv: let
        isCheck = lib.hasPrefix "checks." name;
        wasixMeta = drv.passthru.wasix or {};
        subject = wasixMeta.ciSubject or drv.pname or (lib.getName drv);
        segments = lib.splitString "." name;
        variant =
          if
            lib.length segments
            > 2
            && builtins.elem (builtins.head segments) ["packagesByProfile" "pythonWheels"]
          then builtins.elemAt segments 1
          else null;
        artifactKind =
          if isCheck
          then "test"
          else if lib.hasSuffix ".webc" name
          then "webc"
          else if lib.hasSuffix ".pkg" name
          then "package"
          else "artifact";
      in
        wasixLib.ciInfoOf drv
        // {
          displayName = subject;
          inherit subject;
          testName = wasixMeta.ciTestName or null;
          inherit variant artifactKind;
          tags = wasixLib.ciTagsOf drv;
          role =
            if isCheck
            then "check"
            else "artifact";
          rebuildSignal = true;
          contentDiff = !isCheck;
        }
        // (spotJobInfo.${name} or {}))
      ciSets.all;
      ciSelectorCatalog = {
        jobs = ciJobNames;
        groups = ciGroups;
        info = ciJobInfo;
        sets = lib.mapAttrs (_: jobs: builtins.attrNames jobs) ciSetsDisjoint;
      };
    in
      buildable
      // {
        # Escape hatches / aggregates: reachable via `.#`, but not ci jobs.
        inherit (wasix) nixpkgsByProfile toolchainByProfile defaultProfileName;

        # Rebuild one target against the working tree with everything below it
        # pinned to a pristine base (./spot.nix). A function, so never a ci job.
        spotWith = spotLib.spotWith;
        pkgsCross.wasix = wasix.pkgsCross;
        allWasmerPackages = wasix.allWasmerPackages;

        inherit ciSets ciGroups ciJobInfo ciSelectorCatalog;
        # The pre-rewrite automation's job map; scripts/ci-build.sh and its
        # siblings read it until the workflows move to the new orchestrator.
        ci = ciSets.all;

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
          wheel-natives = run "wheel-natives" [] "python3" "wheel-natives.py";
          preview-diff = run "preview-diff" [] "python3" "preview-diff.py";
          preview-index-deploy = run "preview-index-deploy" [wasmerRuntime p.jq] "bash" "preview-index-deploy.sh";
          # uv: the anybuild retention hook re-resolves its PyPI pins.
          update = run "update" [wasix.nixUpdate p.nix-prefetch-git p.cargo p.uv] "python3" "update.py";
          # Runs the wasix server (overlay package) under wasmer, seeded from the
          # fresh mint; cargo relocks/builds against the local instance.
          cargo-registry-serve = run "cargo-registry-serve" [p.nixVersions.latest p.cargo wasmerRuntime] "python3" "cargo-registry-serve.py";
          # Regenerate pkgs/cargo-registry/crates.json: the concrete fork version
          # set (patch versions + supportedVersions constraints enumerated against
          # the crates.io index) and each crate's hash (.#cargoRegistry.pinInputs).
          crate-pins = run "crate-pins" [p.nixVersions.latest] "python3" "crate-pins.py";
          # Re-resolve the PyPI pins the hermetic anybuild template tests serve
          # as their primary index (pkgs/overlay/packages/anybuild/tests).
          anybuild-mirror = run "anybuild-mirror" [p.uv] "python3" "anybuild-mirror.py";
        };

        remoteIfdProbe = wasix.pkgs.writeText "wasinix-remote-ifd-probe" "ok";
        # Deliberate IFD: evaluating this attr builds the probe, which is how
        # `remote doctor --ifd` verifies a builder can serve import-from-derivation.
        # ciSets derives from `buildable`, never from here, so CI evaluation
        # stays IFD-free; a naive sweep over all of legacyPackages will not.
        remoteIfdProbeResult = builtins.readFile self.legacyPackages.${system}.remoteIfdProbe;

        inherit
          (let
            changelogOf = drv: let
              found = builtins.tryEval (drv.meta.changelog or null);
            in
              if found.success
              then found.value
              else null;
            firstChangelog = drvs:
              lib.findFirst (value: value != null) null (map changelogOf drvs);
            drvPathsByVersion = versionOf: drvs:
              lib.mapAttrs
              (_: values: map (drv: builtins.unsafeDiscardStringContext drv.drvPath) values)
              (lib.groupBy versionOf drvs);
            changelogsByVersion = versionOf: changelogDrvOf: drvs:
              lib.mapAttrs
              (_: values: firstChangelog (map changelogDrvOf values))
              (lib.groupBy versionOf drvs);
            wheelDrvs = name:
              lib.concatMap
              (perPython: lib.attrValues (perPython.${name} or {}))
              (lib.attrValues wasix.pythonRegistry.wheels);
            webcs = lib.groupBy (p: p.pkg.id.name) (lib.attrValues wasix.wasmerPackages);
            relInfo =
              lib.mapAttrs' (name: versions:
                lib.nameValuePair "pythonRegistry.wheels.${name}" {
                  inherit versions;
                  kind = "wheel";
                  changelogs = changelogsByVersion (drv: drv.version) (drv: drv) (wheelDrvs name);
                  derivations = drvPathsByVersion (drv: drv.version) (wheelDrvs name);
                })
              wasix.pythonRegistry.wheelVersions
              // lib.mapAttrs' (name: packages:
                lib.nameValuePair "wasmerPackages.${name}" {
                  versions = lib.unique (map (p: p.pkg.id.baseVersion) packages);
                  kind = "webc";
                  changelogs = changelogsByVersion (p: p.pkg.id.baseVersion) (p: p.pkg) packages;
                  derivations = drvPathsByVersion (p: p.pkg.id.baseVersion) packages;
                })
              webcs
              // lib.mapAttrs' (name: versions:
                lib.nameValuePair "cargoRegistry.crates.${name}" {
                  inherit versions;
                  kind = "crate";
                  changelogs =
                    changelogsByVersion
                    (drv: drv.passthru.version)
                    (drv: drv)
                    (lib.attrValues (wasix.cargoRegistry.crates.${name} or {}));
                  derivations =
                    drvPathsByVersion
                    (drv: drv.passthru.version)
                    (lib.attrValues (wasix.cargoRegistry.crates.${name} or {}));
                })
              wasix.cargoRegistry.crateVersions;
          in {
            inherit relInfo;
            relVersions = lib.mapAttrs (_: info: info.versions) relInfo;
          })
          relInfo
          relVersions
          ;

        # passthru.wasix.updateNotes: things to check when a package moves.
        # `versions` is published in the eval maps; `fired` gets the base branch's
        # copy back as the `prior` side of each note's predicate.
        updateNotes = let
          noted = lib.filterAttrs (_: wasixLib.hasUpdateNotes) ciSets.all;
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

        # passthru.updateScript declarations collected for the update driver, with
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
            # The derivations a command needs realized before it can run; plain
            # strings (nix-update-script argv) carry no derivation, so the
            # derived list keeps only real drv paths rather than null slots.
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
                lib.concatMap (v: lib.optional (lib.isDerivation v) v.drvPath)
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
                    // lib.optionalAttrs (lib.isAttrs s && s ? accepts) {inherit (s) accepts;}
                    // lib.optionalAttrs (lib.isAttrs s && s ? source) {inherit (s) source;}
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
          lib.concatMapAttrs scriptOf ciSets.all;

        # passthru.wasix.retentionHook: a command the update driver runs after the
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
          lib.concatMapAttrs hookOf ciSets.all;
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
      anybuild = wasix.nativePackages.anybuild;
      wasix-rust-toolchain = toolchain.wasixRustToolchain;

      # From-source toolchain parts, buildable in isolation.
      wasix-libc = toolchain.libc;
      # direct cmake of llvm-project, driven by wasix-libc's clang-wasix*.cmake_toolchain
      wasix-compiler-rt = toolchain.compiler-rt;
      wasix-libcxx = toolchain.libcxx;
      wasix-sysroot = toolchain.sysroot;

      wasmer = wasmerRuntime;
    };
  };
}
