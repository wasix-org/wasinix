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
      # fd_sync/fd_datasync refused a directory fd with EISDIR, which every
      # caller that fsyncs a directory after a rename hits (initdb).
      ./patches/wasmer-fd-sync-directory.patch
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
      ./patches/wasmer-epoll-stale-handler-deadlock.patch
    ];
    wasmerRuntime = wasmer.packages.${system}.wasmer.overrideAttrs (old: {
      patches = (old.patches or []) ++ wasmerPatches;
      # The inherited artifact contains unpatched workspace crates and can
      # retain their rlibs and vtables after source patches are applied.
      cargoArtifacts = null;
      # tokio::fs::File stays Busy when a blocking op is cancelled, so the next op
      # re-polls a finished JoinHandle and panics ("JoinHandle polled after
      # completion") onto guest stderr, failing checks that diff guest output.
      cargoVendorDir = old.cargoVendorDir.overrideAttrs (o: {
        nativeBuildInputs = (o.nativeBuildInputs or []) ++ [nixpkgs.legacyPackages.${system}.jq];
        buildCommand =
          o.buildCommand
          + ''
            registry=$(echo "$out"/*/)
            registry=''${registry%/}
            crates=$(readlink -f "$registry")
            rm "$registry"
            mkdir "$registry"
            for crate in "$crates"/*; do
              ln -s "$(readlink -f "$crate")" "$registry/$(basename "$crate")"
            done

            tokio="$registry/tokio-1.53.1"
            if [ ! -L "$tokio" ]; then
              echo "wasmer no longer vendors tokio 1.53.1; recheck patches/tokio-fs-file-no-poison-on-cancel.patch" >&2
              exit 1
            fi
            rm "$tokio"
            cp -rL "$crates/tokio-1.53.1" "$tokio"
            chmod -R u+w "$tokio"
            patch -p2 -d "$tokio" -i ${./patches/tokio-fs-file-no-poison-on-cancel.patch}
            jq '.files = {}' "$tokio/.cargo-checksum.json" > "$tokio/.cargo-checksum.json.new"
            mv "$tokio/.cargo-checksum.json.new" "$tokio/.cargo-checksum.json"
          '';
      });
      passthru =
        (old.passthru or {})
        // {
          wasix = {
            # upstream's version stands still across our rev bumps
            noteVersion = "${old.version}-${wasmer.shortRev or "dirty"}";
            updateNotes = [
              {message = "recheck and drop any Wasmer patches that landed upstream; see WASIX-TODO.md";}
              {message = "check whether tokio PR 8291 landed in the vendored tokio; if so drop patches/tokio-fs-file-no-poison-on-cancel.patch and the patched cargoVendorDir (WASIX-TODO.md)";}
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
        rustfmt.enable = true;
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
    collectTestsPrefixedInto = prefix: initial:
      lib.foldlAttrs (
        acc: name: pkg: let
          tests = pkg.tests;
          fallback = {"${prefix}${name}" = pkg;};
          single = {"${prefix}${name}" = testWithOwner name "tests" tests;};
          testAttrs = let
            declaredCases = (tests.passthru.wasix or {}).testCases or null;
          in
            if declaredCases != null
            then
              lib.mapAttrs'
              (caseName: drv:
                lib.nameValuePair
                "${prefix}${name}-${caseName}"
                (testWithOwner name caseName drv))
              declaredCases
            else if lib.isDerivation tests
            then single
            else fallback;
          entry = builtins.tryEval (lib.optionalAttrs (pkg ? tests) testAttrs);
        in
          acc
          // (
            if entry.success
            then entry.value
            else fallback
          )
      )
      initial;
    collectTestsPrefixed = prefix: collectTestsPrefixedInto prefix {};
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
    # The orchestrator binary. Vanilla nixpkgs Rust: this is the tool that
    # tests the wasix toolchain, so it must not depend on it.
    wasinixUnwrapped = wasix.pkgs.rustPlatform.buildRustPackage {
      pname = "wasinix";
      version = "0.1.0";
      src = ./tools/wasinix;
      cargoLock.lockFile = ./tools/wasinix/Cargo.lock;
      doCheck = true;
      nativeCheckInputs = with wasix.pkgs; [gitMinimal nixVersions.latest];
      meta.mainProgram = "wasinix";
    };
    # Every command is runnable from the same installed closure, so a remote
    # host reached with `nix run .#wasinix` needs no ambient tools.
    wasinixLauncher = wasix.pkgs.writeShellApplication {
      name = "wasinix";
      inheritPath = false;
      runtimeInputs = with wasix.pkgs; [
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
    wasinix = wasix.pkgs.symlinkJoin {
      name = "wasinix";
      paths = [wasinixLauncher];
      nativeBuildInputs = [wasix.pkgs.installShellFiles];
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
          wasix.pkgs.writeShellApplication {
            inherit name;
            inheritPath = false;
            runtimeInputs = [wasinix];
            text = "exec wasinix ${name} \"$@\"";
          }
      );
    wasinixInterfaceCheck =
      wasix.pkgs.runCommand "wasinix-interface-check" {
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
    # End to end for `wasinix cargo publish`: the real wasm server under
    # wasmer, a fabricated one-crate mint, then dry-run inertness, publish,
    # checksum idempotence, the conflict remedy, and a cargo consume over
    # sparse+loopback.
    wasinixCargoPublishCheck =
      wasix.pkgs.runCommandCC "wasinix-cargo-publish-check" {
        nativeBuildInputs = [
          wasinixUnwrapped
          wasmerRuntime
          wasix.pkgs.python3
          wasix.pkgs.cargo
          wasix.pkgs.rustc
          wasix.pkgs.curl
          wasix.pkgs.gnutar
          wasix.pkgs.gzip
          wasix.pkgs.writableTmpDirAsHomeHook
        ];
        publisher = ./pkgs/cargo-registry/publish-crate.py;
        server = wasix.wasmerPackages."wasix-cargo-registry";
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
          grep -q 'versions bump cargoRegistry.crates.probe@0.1.0' conflict.txt
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
      wasix.pkgs.runCommand "wasinix-wasmer-serve-check" {
        nativeBuildInputs = [wasinixUnwrapped wasmerRuntime wasix.pkgs.writableTmpDirAsHomeHook];
        bashWebc = wasix.wasmerPackages.bash.webc;
        bashDeps = wasix.wasmerPackages.bash.pkg.depTree;
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
      wasix.pkgs.runCommand "wasinix-serve-all-check" {
        nativeBuildInputs = [
          wasinixUnwrapped
          wasmerRuntime
          wasix.pkgs.python3
          wasix.pkgs.curl
          wasix.pkgs.gnutar
          wasix.pkgs.gzip
          wasix.pkgs.writableTmpDirAsHomeHook
        ];
        publisher = ./pkgs/cargo-registry/publish-crate.py;
        server = wasix.wasmerPackages."wasix-cargo-registry";
        bashWebc = wasix.wasmerPackages.bash.webc;
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
    packageChecks = let
      wasmerChecks = collectTests (removeAttrs wasix.wasmerPackageInventory ["rust"]);
      rustChecks =
        wasmerChecks
        // lib.optionalAttrs (wasix.wasmerPackageInventory ? rust) {rust-webc = wasix.wasmerPackageInventory.rust.tests.all;};
      libraryChecks =
        lib.foldlAttrs
        (acc: profile: packages: collectTestsPrefixedInto "lib-${profile}-" acc packages)
        rustChecks
        wasix.ciPackagesByProfile;
      registryChecks = collectTestsPrefixedInto "" libraryChecks {cargo-registry = wasix.cargoRegistry;};
      abiChecks = registryChecks // lib.mapAttrs' (p: lib.nameValuePair "abi-${p}") wasix.abiChecks;
    in
      collectTestsPrefixedInto "" abiChecks wasix.libraryTestPkgs;
    checksBySet = {
      core = mergeDisjoint "checksBySet.core" [
        {
          wasinix = wasinixUnwrapped;
          wasinix-interface = wasinixInterfaceCheck;
          wasinix-cargo-publish = wasinixCargoPublishCheck;
          wasinix-wasmer-serve = wasinixWasmerServeCheck;
          wasinix-serve-all = wasinixServeAllCheck;
        }
        (collectTests wasix.toolchainTestPkgs)
      ];
      packages = packageChecks;
      python = mergeDisjoint "checksBySet.python" [
        # pythonWheels is nested by version; collect as wheel-py314-<attr>.
        (lib.concatMapAttrs (pv: wheelSet: collectTestsPrefixed "wheel-${pv}-" wheelSet) wasix.pythonWheels)
        (collectTests {python-registry = wasix.pythonRegistry;})
        (lib.mapAttrs' (name: lib.nameValuePair "pyclosure-${name}") wasix.pythonClosureTests)
      ];
    };
    regularFlakeChecks = mergeDisjoint "checks" ([{treefmt = treefmtCheck;}] ++ builtins.attrValues checksBySet);
    evalSanityChecks =
      lib.concatMapAttrs (
        profile: packages:
          lib.mapAttrs' (
            name: check: lib.nameValuePair "eval-sanity-${profile}-${name}" check
          )
          packages
      )
      wasix.evalSanity;
    flakeChecks = regularFlakeChecks // evalSanityChecks;
  in {
    formatter.${system} = treefmtEval.config.build.wrapper;

    apps.${system} =
      lib.mapAttrs (_: command: {
        type = "app";
        program = lib.getExe command;
      })
      commands;

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
          inherit (wasix.toolchainTestPkgs) sysroot tinygo wasixcc;

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
        pythonClosureTests = wasix.pythonClosureTests;
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
          # The orchestrator itself: as a job its closure reaches the cache,
          # so workflow steps running `nix run .#wasinix` substitute instead
          # of compiling the crate and its tests from source.
          (flattenDrvs "" {inherit wasinix;})
          (flattenDrvs "checks" checksBySet.core)
          (lib.mapAttrs' (name: check: lib.nameValuePair "checks.${name}" check) evalSanityChecks)
        ];
        packages = [
          # The package-declared coverage, not every profile a package supports.
          (flattenDrvs "packagesByProfile" wasix.ciPackagesByProfile)
          (flattenDrvs "wasmerPackages" wasix.wasmerPackageInventory)
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
        emulated = {
          jobs =
            lib.filter
            (name: lib.hasPrefix "checks." name && lib.hasSuffix "-upstream" name)
            ciJobNames;
          spotOwners = [];
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
      wasmerJobAliases =
        lib.concatMapAttrs (packageKey: package: let
          aliases = package.passthru.wasmer.aliases or [];
          addresses = map (alias: "wasmerPackages.${alias}") aliases;
        in {
          "wasmerPackages.${packageKey}" = addresses;
          "wasmerPackages.${packageKey}.webc" = map (address: "${address}.webc") addresses;
        })
        wasix.wasmerPackageInventory;
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
          testFamily =
            if lib.hasPrefix "checks.wheel-" name
            then "wheel"
            else if lib.hasPrefix "checks.lib-" name
            then "library"
            else null;
          inherit variant artifactKind;
          aliases = wasmerJobAliases.${name} or [];
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
      # The derivations an updateScript or retentionHook command needs realised
      # before it can run. A command element is usually a string with an
      # interpolated store path, so the drv paths live in its string context,
      # not in the value's type.
      commandDrvsOf = lib.concatMap (
        v:
          if lib.isDerivation v
          then [v.drvPath]
          else builtins.attrNames (builtins.getContext (toString v))
      );
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
        inherit (wasix) wasixRun;

        inherit ciSets ciGroups ciJobInfo ciSelectorCatalog;
        # The flat job map the docs teach as `.#ci`.
        ci = ciSets.all;

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
            webcs = lib.groupBy (p: p.pkg.id.name) (lib.attrValues wasix.wasmerPackageInventory);
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
            commandDrvPaths =
              if commandValues == null
              then null
              else commandDrvsOf commandValues;
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

        # passthru.wasix.postUpdateHook: a command the update driver runs when
        # its package version moves. In-tree only; the driver dedupes repeats.
        postUpdateHooks = let
          srcRoot = toString self;
          hookOf = attr: drv: let
            h = (drv.passthru.wasix or {}).postUpdateHook or null;
            command =
              if h == null
              then null
              else map toString (lib.toList h);
            commandDrvPaths =
              if h == null
              then null
              else commandDrvsOf (lib.toList h);
            pos = builtins.unsafeGetAttrPos "wasix" (drv.passthru or {});
            ours =
              command
              != null
              && command != []
              && pos != null
              && lib.hasPrefix srcRoot pos.file;
            entry = builtins.tryEval (
              let
                v = lib.optionalAttrs ours {
                  ${attr} = {
                    inherit command commandDrvPaths;
                    version = toString drv.version;
                  };
                };
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
        wasinix
        toolchain.wasixcc
        toolchain.cargoWasix
        wasix.nixpkgsByProfile.${wasix.defaultProfileName}.ncurses
        wasix.pkgs.gnumake
        wasix.pkgs.pkg-config
        wasmerRuntime

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
      inherit wasinix;
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
