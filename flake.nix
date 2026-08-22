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
      # The official read-only mirror of gitlab.haskell.org/haskell-wasm:
      # same commits, narHash-verified, and CI already depends on github,
      # so a gitlab outage cannot take evaluation down with it.
      url = "github:haskell-wasm/ghc-wasm-meta";
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
    projectApi = import ./pkgs/project/wasinix.nix {
      lib = nixpkgs.lib;
      ghcWasm = ghc-wasm-meta.packages.${system};
      wasmerPackage = wasmer.packages.${system}.wasmer;
      wasmerRevision = wasmer.shortRev or "dirty";
    };
    project = projectApi.mkProject {
      inherit system;
      importNixpkgs = args: import nixpkgs args;
      ci.sources = ["wasinix"];
    };
    pkgs = project.internals.packageSets.nativeRaw;
    inherit (pkgs) lib;
    wasmerRuntime = project.packages.native.wasmer;
    wasixLib = import ./pkgs/lib {inherit lib;};

    treefmtEval = treefmt-nix.lib.evalModule pkgs {
      projectRootFile = "flake.nix";
      # Captured tool output, compared byte for byte by the tests.
      settings.global.excludes = ["tools/wasinix/fixtures/golden/*"];
      programs = {
        alejandra.enable = true; # nix
        ruff-format.enable = true; # python
        # shell
        shfmt = {
          enable = true;
          indent_size = 2;
        };
        taplo.enable = true; # toml
        clang-format.enable = true; # c/c++
        # json stays out, as the only json in this repo is machine-generated
        prettier = {
          enable = true;
          includes = ["*.js" "*.yml" "*.yaml" "*.md"];
        };
        rustfmt.enable = true;
      };
    };
    treefmtCheck = treefmtEval.config.build.check self;

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

    # The orchestrator binary. Vanilla nixpkgs Rust: this is the tool that
    # tests the wasix toolchain, so it must not depend on it.
    wasinixUnwrapped = pkgs.rustPlatform.buildRustPackage {
      pname = "wasinix";
      version = "0.1.0";
      src = ./tools/wasinix;
      cargoLock.lockFile = ./tools/wasinix/Cargo.lock;
      doCheck = true;
      nativeCheckInputs = with pkgs; [gitMinimal nixVersions.latest];
      meta.mainProgram = "wasinix";
    };
    # Every command is runnable from the same installed closure, so a remote
    # host reached with `nix run .#wasinix` needs no ambient tools.
    wasinixLauncher = pkgs.writeShellApplication {
      name = "wasinix";
      inheritPath = false;
      runtimeInputs = with pkgs; [
        awscli2
        bash
        coreutils
        git
        nix-eval-jobs
        nixVersions.latest
        openssh
        python3
        rclone
        wasmerRuntime
      ];
      # Update scripts re-enter `wasinix`, so the launcher's own bin dir joins
      # the PATH it hands them.
      text = ''
        PATH="''${0%/*}:$PATH" exec ${lib.getExe wasinixUnwrapped} "$@"
      '';
    };
    wasinix = pkgs.symlinkJoin {
      name = "wasinix";
      paths = [wasinixLauncher];
      nativeBuildInputs = [pkgs.installShellFiles];
      postBuild = ''
        installShellCompletion --cmd wasinix \
          --bash <(${lib.getExe wasinixUnwrapped} completions bash) \
          --fish <(${lib.getExe wasinixUnwrapped} completions fish) \
          --zsh <(${lib.getExe wasinixUnwrapped} completions zsh)
      '';
      meta.mainProgram = "wasinix";
    };
    # One alias per top-level command; the interface check keeps this list and
    # the CLI from drifting apart.
    commandAliases = ["build" "spot" "diff" "run" "remote" "ci"];
    commands =
      {
        default = wasinix;
        inherit wasinix;
      }
      // lib.genAttrs commandAliases (
        name:
          pkgs.writeShellApplication {
            inherit name;
            inheritPath = false;
            runtimeInputs = [wasinix];
            text = "exec wasinix ${name} \"$@\"";
          }
      );
    wasinixInterfaceCheck =
      pkgs.runCommand "wasinix-interface-check" {
        nativeBuildInputs = builtins.attrValues commands;
      } ''
        wasinix --help >/dev/null
        for command in ${lib.escapeShellArgs commandAliases}; do
          "$command" --help >/dev/null
        done
        for shell in bash fish zsh; do
          wasinix completions "$shell" >/dev/null
        done
        touch "$out"
      '';
    sourceShapeCheck =
      pkgs.runCommand "wasinix-source-shape-check" {
        nativeBuildInputs = [pkgs.ripgrep];
      } ''
        if rg -n \
          'passthru\.wasix\.(shipped|ciProfiles|ciTags|emulatedCheck|installCheck|interpreterSpecific|publication|retention|smokeTest|testExpectation|updateNotes|postUpdateHook)|passthru\.wasmer\.(aliases|smokeArgs)|\bwasix\.(shipped|interpreterSpecific|retention|updateNotes|postUpdateHook)|helpers\.libTweaks|\blibTweaks\s*=' \
          ${self}/pkgs; then
          echo "A removed Wasinix source shape is still in use" >&2
          exit 1
        fi
        touch "$out"
      '';
    # End to end for `wasinix cargo publish`: the real wasm server under
    # wasmer, a fabricated one-crate mint, then dry-run inertness, publish,
    # checksum idempotence, the conflict remedy, and a cargo consume over
    # sparse+loopback.
    wasinixCargoPublishCheck =
      pkgs.runCommandCC "wasinix-cargo-publish-check" {
        nativeBuildInputs = [
          wasinixUnwrapped
          wasmerRuntime
          pkgs.python3
          pkgs.cargo
          pkgs.rustc
          pkgs.curl
          pkgs.gnutar
          pkgs.gzip
          pkgs.writableTmpDirAsHomeHook
        ];
        publisher = ./pkgs/cargo-registry/publish-crate.py;
        server = project.packages.preferred.cargo-registry;
      } ''
        set -u
        port=8733
        base="http://127.0.0.1:$port"
        token=wasix_test
        export WASMER_DIR="$PWD/.wasmer"

        # A one-crate mint in the manifest shape the real mint emits; $2
        # varies the payload so a second mint conflicts by checksum.
        make_mint() {
          mkdir -p "$1/work/probe-0.1.0+wasix.1/src" "$1/crates"
          cat > "$1/work/probe-0.1.0+wasix.1/Cargo.toml" <<'EOF'
        [package]
        name = "probe"
        version = "0.1.0+wasix.1"
        edition = "2021"
        EOF
          printf 'pub fn ok() -> u32 { %s }\n' "$2" > "$1/work/probe-0.1.0+wasix.1/src/lib.rs"
          tar czf "$1/crates/probe-0.1.0+wasix.1.crate" -C "$1/work" "probe-0.1.0+wasix.1"
          rm -r "$1/work"
          cp "$publisher" "$1/publish-crate.py"
          cat > "$1/manifest.json" <<'EOF'
        {"crates":[{"crate":"probe","wasixVersion":"0.1.0+wasix.1","crateFile":"probe-0.1.0+wasix.1.crate","upstream":"0.1.0","rel":1}],"shadowLimits":[],"excluded":[],"unpinned":[],"stray":[]}
        EOF
        }
        make_mint mint1 42
        make_mint mint2 43

        mkdir -p data
        wasmer run "$server/bin/wasix-cargo-registry.wasm"           --net --enable-threads           --volume "$PWD/data:/data"           --env "REGISTRY_LISTEN_ADDR=0.0.0.0:$port"           --env "REGISTRY_BASE_URL=$base"           --env "REGISTRY_AUTH_TOKEN_HASHES=$(printf %s "$token" | sha256sum | cut -d' ' -f1)"           --env "REGISTRY_STORAGE_PATH=/data" &
        server_pid=$!
        trap 'kill $server_pid 2>/dev/null || true' EXIT
        for _ in $(seq 1 150); do
          kill -0 $server_pid 2>/dev/null || { echo "server exited early" >&2; exit 1; }
          curl -fsS "$base/config.json" >/dev/null 2>&1 && break
          sleep 0.2
        done
        curl -fsS "$base/config.json" >/dev/null

        # A dry run needs no token and writes nothing.
        wasinix cargo publish --mint mint1 --registry "$base" --dry-run
        if curl -fsS "$base/pr/ob/probe" 2>/dev/null | grep -q '"vers"'; then
          echo "dry run published" >&2; exit 1
        fi

        WASIX_CARGO_TOKEN=$token wasinix cargo publish --mint mint1 --registry "$base"
        curl -fsS "$base/pr/ob/probe" | grep -q '"vers":"0.1.0+wasix.1"'

        # Idempotence: the second run skips by checksum and needs no token.
        wasinix cargo publish --mint mint1 --registry "$base" --json > again.json
        python3 - <<'PY'
        import json
        report = json.load(open("again.json"))
        [outcome] = report["outcomes"]
        assert outcome["action"] == "skip", outcome
        assert not outcome["published"], outcome
        PY

        # Same version, different bytes: a conflict naming the rel-bump
        # remedy, and no republish, even under --dry-run.
        for extra in "" "--dry-run"; do
          if WASIX_CARGO_TOKEN=$token wasinix cargo publish --mint mint2               --registry "$base" $extra > conflict.txt; then
            echo "conflicting publish succeeded" >&2; exit 1
          fi
          grep -q 'versions bump artifacts.registry.cargo-registry.crates.probe@0.1.0' conflict.txt
        done

        # The published crate resolves and compiles through the sparse index.
        mkdir -p app/src app/.cargo
        cat > app/Cargo.toml <<'EOF'
        [package]
        name = "consume"
        version = "0.0.0"
        edition = "2021"
        [dependencies]
        probe = "0.1.0"
        EOF
        cat > app/.cargo/config.toml <<EOF
        [source.crates-io]
        replace-with = "wasix"
        [source.wasix]
        registry = "sparse+$base/"
        EOF
        echo 'fn main() { assert_eq!(probe::ok(), 42); }' > app/src/main.rs
        ( cd app && CARGO_HOME="$PWD/../cargo-home" cargo run --quiet )
        touch "$out"
      '';
    # `wasinix wasmer serve` from prebuilt webcs (no nix in the sandbox):
    # the merged tree runs a shipped command fully offline through the
    # WASMER_FLAGS the --exec contract sets.
    wasinixWasmerServeCheck =
      pkgs.runCommand "wasinix-wasmer-serve-check" {
        nativeBuildInputs = [wasinixUnwrapped wasmerRuntime pkgs.writableTmpDirAsHomeHook];
        bashWebc = project.artifacts.webc.bash;
        bashDeps = project.artifacts.pkg.bash.depTree;
      } ''
        export WASMER_DIR="$PWD/.wasmer"
        wasinix wasmer serve --webc "$bashWebc" --webc "$bashDeps" --out tree -- sh -c '
          set -eu
          file=$(ls tree/wasmer/bash)
          ref="wasmer/bash@''${file%.webc}"
          # shellcheck disable=SC2086
          out=$(wasmer run $WASMER_FLAGS "$ref" -- -c "echo served-offline")
          [ "$out" = served-offline ]
        '
        touch "$out"
      '';
    # The meta serve fan-out: all three registries live at once, probed
    # through one --exec, torn down by one exit.
    wasinixServeAllCheck =
      pkgs.runCommand "wasinix-serve-all-check" {
        nativeBuildInputs = [
          wasinixUnwrapped
          wasmerRuntime
          pkgs.python3
          pkgs.curl
          pkgs.gnutar
          pkgs.gzip
          pkgs.writableTmpDirAsHomeHook
        ];
        publisher = ./pkgs/cargo-registry/publish-crate.py;
        server = project.packages.preferred.cargo-registry;
        bashWebc = project.artifacts.webc.bash;
      } ''
        export WASMER_DIR="$PWD/.wasmer"
        mkdir -p mint/work/probe-0.1.0+wasix.1/src mint/crates index/simple
        cat > mint/work/probe-0.1.0+wasix.1/Cargo.toml <<'EOF'
        [package]
        name = "probe"
        version = "0.1.0+wasix.1"
        edition = "2021"
        EOF
        echo 'pub fn ok() {}' > mint/work/probe-0.1.0+wasix.1/src/lib.rs
        tar czf mint/crates/probe-0.1.0+wasix.1.crate -C mint/work probe-0.1.0+wasix.1
        rm -r mint/work
        cp "$publisher" mint/publish-crate.py
        cat > mint/manifest.json <<'EOF'
        {"crates":[{"crate":"probe","wasixVersion":"0.1.0+wasix.1","crateFile":"probe-0.1.0+wasix.1.crate","upstream":"0.1.0","rel":1}],"shadowLimits":[],"excluded":[],"unpinned":[],"stray":[]}
        EOF
        echo '<html></html>' > index/simple/index.html
        wasinix serve --mint mint --index index --server "$server" --webc "$bashWebc" -- sh -c '
          set -eu
          curl -fsS http://127.0.0.1:8319/config.json >/dev/null
          curl -fsS http://127.0.0.1:8318/simple/ >/dev/null
          case "$WASMER_FLAGS" in *--include-webc*) : ;; *) echo "no webc tree in WASMER_FLAGS" >&2; exit 1 ;; esac
        '
        touch "$out"
      '';
    repositoryChecks = {
      "tests.project.treefmt" = treefmtCheck;
      "tests.project.wasinix" = wasinixUnwrapped;
      "tests.project.wasinix-interface" = wasinixInterfaceCheck;
      "tests.project.wasinix-source-shape" = sourceShapeCheck;
      "tests.project.wasinix-cargo-publish" = wasinixCargoPublishCheck;
      "tests.project.wasinix-wasmer-serve" = wasinixWasmerServeCheck;
      "tests.project.wasinix-serve-all" = wasinixServeAllCheck;
    };
    repositoryCatalogEntries =
      lib.mapAttrs (address: check: {
        kind = "test";
        inherit address check;
        name = lib.last (lib.splitString "." address);
        testName = lib.last (lib.splitString "." address);
        source = "wasinix";
        lineage = ["wasinix"];
        scope = "native";
        variant = {};
        instance = {
          kind = "current";
          version = toString (check.version or check.name);
        };
        subject = "project";
        packageSubject = "project";
        policy = {
          aliases = [];
          shipped = false;
          ci = {};
          publication = {};
          retention = null;
        };
      })
      repositoryChecks;
    repositoryCiCatalog =
      lib.mapAttrs (_: entry: builtins.removeAttrs entry ["check"])
      repositoryCatalogEntries;
    allCiJobs = mergeDisjoint "project CI jobs" [project.ci.jobs repositoryChecks];
    allCiCatalog = mergeDisjoint "project CI catalog" [project.ci.catalog.jobs repositoryCiCatalog];
    jobsForSubjects = subjects:
      map (entry: entry.address) (lib.filter (entry:
        builtins.elem (entry.packageSubject or entry.address) subjects)
      (builtins.attrValues allCiCatalog));
    nativeSubjects = names: map (name: "packages.native.${name}") names;
    toolchainNames = [
      "cargo-wasix"
      "cargo-wasix-unwrapped"
      "wasix-flang"
      "wasix-llvm"
      "wasix-rust"
      "wasix-sysroot"
      "wasix-tinygo"
      "wasixcc"
      "wasixcc-unwrapped"
    ];
    ccNames = [
      "wasix-flang"
      "wasix-llvm"
      "wasix-sysroot"
      "wasix-tinygo"
      "wasixcc"
      "wasixcc-unwrapped"
    ];
    rustNames = ["cargo-wasix" "cargo-wasix-unwrapped" "wasix-rust"];
    selectorGroups = {
      toolchain = {
        jobs = jobsForSubjects (nativeSubjects toolchainNames);
        spotOwners = ["stdenv" "rustPlatform" "haskellPackages"];
      };
      cc = {
        jobs = jobsForSubjects (nativeSubjects ccNames);
        spotOwners = ["stdenv"];
      };
      rust = {
        jobs = jobsForSubjects (nativeSubjects rustNames);
        spotOwners = ["rustPlatform"];
      };
      haskell = {
        jobs = jobsForSubjects (map (profile: "packages.wasix.${profile}.pandoc") (builtins.attrNames project.packages.wasix));
        spotOwners = ["haskellPackages"];
      };
      emulated = {
        jobs = map (entry: entry.address) (lib.filter (entry: entry.testName or null == "captured") (builtins.attrValues allCiCatalog));
        spotOwners = [];
      };
    };
    publicationInfo = let
      registry = project.artifacts.registry.python314;
      cargoRegistryArtifact = project.artifacts.registry.cargo-registry;
      firstChangelog = derivations:
        lib.findFirst (value: value != null) null
        (map (derivation: let
          attempted = builtins.tryEval (derivation.meta.changelog or null);
        in
          if attempted.success
          then attempted.value
          else null)
        derivations);
      informationFor = {
        kind,
        versionOf,
        changelogOf ? (derivation: derivation),
        derivations,
      }: {
        versions = lib.unique (map versionOf derivations);
        inherit kind;
        changelogs =
          lib.mapAttrs (_: values: firstChangelog (map changelogOf values))
          (lib.groupBy versionOf derivations);
        derivations = lib.mapAttrs (_: values:
          map (derivation: builtins.unsafeDiscardStringContext derivation.drvPath) values)
        (lib.groupBy versionOf derivations);
      };
      wheelDerivations = name:
        lib.concatMap (perInterpreter: lib.attrValues (perInterpreter.${name} or {}))
        (lib.attrValues registry.wheels);
      wheelInfo = lib.mapAttrs' (name: _:
        lib.nameValuePair "artifacts.registry.python314.wheels.${name}" (informationFor {
          kind = "wheel";
          versionOf = derivation: derivation.version;
          derivations = wheelDerivations name;
        }))
      registry.wheelVersions;
      webcInfo = lib.mapAttrs' (name: package:
        lib.nameValuePair "artifacts.webc.${name}" (informationFor {
          kind = "webc";
          versionOf = derivation: derivation.id.baseVersion;
          derivations = [package] ++ builtins.attrValues (package.versions or {});
        }))
      project.artifacts.pkg;
      cargoInfo = lib.mapAttrs' (name: _:
        lib.nameValuePair "artifacts.registry.cargo-registry.crates.${name}" (informationFor {
          kind = "crate";
          versionOf = derivation: derivation.passthru.version;
          derivations = builtins.attrValues (cargoRegistryArtifact.crates.${name} or {});
        }))
      cargoRegistryArtifact.crateVersions;
    in
      wheelInfo // webcInfo // cargoInfo;
    updateCandidates = let
      from = prefix: packages:
        lib.mapAttrs' (name: package: lib.nameValuePair "${prefix}.${name}" package)
        (lib.filterAttrs (_: package: (package.passthru.wasinix.source or null) == "wasinix") packages);
    in
      from "packages.native" project.packages.native
      // from "packages.wasix" project.packages.preferred
      // from "packages.python.py314" project.packages.python.py314;
    commandDrvsOf = lib.concatMap (value:
      if lib.isDerivation value
      then [value.drvPath]
      else builtins.attrNames (builtins.getContext (toString value)));
    updateScripts = let
      srcRoot = toString self;
      scriptFor = address: package: let
        declaration = package.passthru.updateScript or null;
        commandValues =
          if lib.isList declaration
          then declaration
          else if lib.isAttrs declaration && declaration ? command
          then lib.toList declaration.command
          else null;
        command =
          if commandValues == null
          then null
          else map toString commandValues;
        position = builtins.unsafeGetAttrPos "updateScript" (package.passthru or {});
        ours =
          command
          != null
          && command != []
          && position != null
          && lib.hasPrefix srcRoot position.file;
        value = lib.optionalAttrs ours {
          ${address} =
            {
              inherit command;
              commandDrvPaths = commandDrvsOf commandValues;
              version = package.version or null;
              position = package.meta.position or null;
            }
            // lib.optionalAttrs (lib.isAttrs declaration && declaration ? name) {inherit (declaration) name;}
            // lib.optionalAttrs (lib.isAttrs declaration && declaration ? attrPath) {inherit (declaration) attrPath;}
            // lib.optionalAttrs (lib.isAttrs declaration && declaration ? accepts) {inherit (declaration) accepts;}
            // lib.optionalAttrs (lib.isAttrs declaration && declaration ? source) {inherit (declaration) source;};
        };
        result = builtins.tryEval (builtins.deepSeq value value);
      in
        if result.success
        then result.value
        else {};
    in
      lib.concatMapAttrs scriptFor updateCandidates;
    updateNotes = let
      noted = lib.filterAttrs (_: wasixLib.hasUpdateNotes) updateCandidates;
      versionOf = package: let
        attempted = builtins.tryEval (wasixLib.noteVersionOf package);
      in
        if attempted.success
        then attempted.value
        else null;
    in {
      versions = lib.mapAttrs (_: versionOf) noted;
      fired = priors:
        lib.filterAttrs (_: notes: notes != [])
        (lib.mapAttrs (address: wasixLib.firedNotesOf (priors.${address} or null)) noted);
    };
    postUpdateHooks = let
      srcRoot = toString self;
      hookFor = address: package: let
        declaration = (package.passthru.wasinix.update or {}).post or null;
        command =
          if declaration == null
          then null
          else map toString (lib.toList declaration);
        position = builtins.unsafeGetAttrPos "wasinix" (package.passthru or {});
        ours =
          command
          != null
          && command != []
          && position != null
          && lib.hasPrefix srcRoot position.file;
        value = lib.optionalAttrs ours {
          ${address} = {
            inherit command;
            commandDrvPaths = commandDrvsOf (lib.toList declaration);
            version = package.version or null;
          };
        };
        result = builtins.tryEval (builtins.deepSeq value value);
      in
        if result.success
        then result.value
        else {};
    in
      lib.concatMapAttrs hookFor updateCandidates;
    systemProject =
      project
      // {
        tests = project.tests // repositoryChecks;
        catalog.entries = project.catalog.entries // repositoryCatalogEntries;
        internals =
          project.internals
          // {
            publication = {
              info = publicationInfo;
              versions = lib.mapAttrs (_: info: info.versions) publicationInfo;
            };
            updates = {
              inherit postUpdateHooks updateNotes updateScripts;
            };
          };
        ci =
          project.ci
          // {
            jobs = allCiJobs;
            catalog =
              project.ci.catalog
              // {
                jobs = allCiCatalog;
                selectors.sets =
                  project.ci.catalog.selectors.sets
                  // {
                    core = (project.ci.catalog.selectors.sets.core or []) ++ builtins.attrNames repositoryChecks;
                  };
                selectors.groups = selectorGroups;
              };
          };
      };
  in {
    lib = projectApi;
    formatter.${system} = treefmtEval.config.build.wrapper;
    apps.${system} =
      lib.mapAttrs (_: command: {
        type = "app";
        program = lib.getExe command;
      })
      commands;
    legacyPackages.${system} = systemProject;
    checks.${system} = systemProject.tests;
    packages.${system} = {
      default = wasinix;
      inherit wasinix;
    };
    devShells.${system}.default = pkgs.mkShell {
      packages = [
        wasinix
        project.packages.native.cargo-wasix
        project.packages.native.wasixcc
        project.packages.preferred.ncurses
        pkgs.gnumake
        pkgs.pkg-config
        wasmerRuntime
        pkgs.nix-eval-jobs
        pkgs.nixVersions.latest
      ];
    };
  };
}
