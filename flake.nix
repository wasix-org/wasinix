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
    wasmerRuntime = wasmer.packages.${system}.wasmer.overrideAttrs (old: {
      patches =
        (old.patches or [])
        ++ [
          # proc_fork must inherit the parent's signal dispositions; see WASIX-TODO.md
          ./patches/wasmer-signal-inherit-on-fork.patch
        ];
      passthru =
        (old.passthru or {})
        // {
          wasix.updateNotes = [
            {message = "check whether patches/wasmer-signal-inherit-on-fork.patch landed upstream (WASIX-TODO.md)";}
          ];
        };
    });
    wasix = import ./pkgs {
      inherit system nixpkgs;
      # runs the behavioural passthru.tests on the webc packages.
      inherit wasmerRuntime;
      # bindist GHC for the wasi haskell toolchain (toolchain.haskell); pandoc
      # (overlay/packages/pandoc) builds against it. TemplateHaskell works under
      # node there (memory: wasix-haskell-th-blocked).
      ghcWasm = ghc-wasm-meta.packages.${system};
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
    # shipped packages). tryEval guards the `pkg ? tests` probe (it forces pkg):
    # a throwing pkg must not abort the whole `checks` output, but its entry is
    # KEPT so the error surfaces as a failed check instead of vanishing.
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
      # Declared breakage (meta.broken via passthru.wasix.broken, fd/tokei) is
      # dropped from the job set; unsupported-profile leaves are already
      # filtered out of librariesByProfile in pkgs/default.nix. Only meta is
      # read (never drvPath): the key set must stay cheap, since every
      # nix-eval-jobs worker computes it before its first job, and probing
      # drvPath would instantiate the whole matrix per worker. A leaf that
      # throws is KEPT: nix-eval-jobs evaluates attrs independently, so it
      # surfaces as one failed job with the error at its attr path instead of
      # silently vanishing from CI.
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
            # Classification forces val shallowly and can throw; keep such a
            # leaf under its key so the error is attributed to it.
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
          # inheritPath = false: PATH is exactly the declared deps, so a script
          # reaching for an undeclared tool fails loudly instead of silently
          # picking up the ambient one. Common to every wrapper: git, coreutils,
          # a pinned nix, and the interpreter (which must be on PATH itself now
          # that we don't inherit it). Per-script lists carry only the extras.
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
                  # CI log capture block-buffers python stdout, hiding all
                  # progress until exit (or forever on cancel)
                  lib.optionalString (interp == "python3") "export PYTHONUNBUFFERED=1"
                }
                exec ${interp} ${file} "$@"
              '';
            };
        in {
          ci-build = run "ci-build" [p.jq p.nix-eval-jobs p.nix-fast-build p.findutils] "bash" ./scripts/ci-build.sh;
          rebuild-diff = run "rebuild-diff" [p.python3 p.nix-eval-jobs] "bash" ./scripts/rebuild-diff.sh;
          content-diff = run "content-diff" [] "python3" ./scripts/content-diff.py;
          ci-report = run "ci-report" [] "python3" ./scripts/ci-report.py;
          publish-eval-map = run "publish-eval-map" [p.awscli2] "bash" ./scripts/publish-eval-map.sh;
          bump-rel = run "bump-rel" [] "python3" ./scripts/bump-rel.py;
          publish-index = run "publish-index" [wasmerRuntime p.rclone p.python3 p.gawk p.gnused] "bash" ./scripts/publish-index.sh;
          publish-webc = run "publish-webc" [wasmerRuntime] "python3" ./scripts/publish-webc.py;
          update = run "update" [p.nix-update p.nix-prefetch-git p.cargo] "python3" ./scripts/update.py;
        };

        # rels.json key -> list of served upstream versions (wheels can serve history versions
        # besides the current one; webcs serve exactly one). Read by scripts/update.py (prune
        # stale keys) and scripts/bump-rel.py (validate + look up).
        relVersions =
          lib.mapAttrs' (n: v: lib.nameValuePair "pythonRegistry.wheels.${n}" v)
          wasix.pythonRegistry.wheelVersions
          # webcs group by published name: history versions key wasmerPackages
          # as <name>-<semver> but publish under the same name.
          // lib.mapAttrs' (name: ps:
            lib.nameValuePair "wasmerPackages.${name}"
            (lib.unique (map (p: p.pkg.id.baseVersion) ps)))
          (lib.groupBy (p: p.pkg.id.name) (lib.attrValues wasix.wasmerPackages));

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
        nixpkgs.legacyPackages.${system}.nixVersions.latest
      ];
      shellHook = ''
        ${wasix.toolchainByProfile.${wasix.defaultProfileName}.toolchainEnv}
        ${wasix.toolchainByProfile.${wasix.defaultProfileName}.ccEnv}
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
  };
}
