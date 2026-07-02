{
  system,
  nixpkgs,
  # the wasmer runtime used to run behavioural tests (passthru.tests on the webc
  # packages). A flake-level input; null falls back to nixpkgs' wasmer.
  wasmerRuntime ? null,
}: let
  pkgs = import nixpkgs {inherit system;};
  inherit (pkgs) lib;
  foundation = import ./toolchain {inherit pkgs;};

  # The single wasix cross target. Kept here (rather than derived from a
  # toolchain profile) so pkgsCross can be built *before* the profiles — each
  # profile now consumes pkgsCross to build its first-class cc-wrapper stdenv.
  crossSystem = {
    # Keep nixpkgs parser-compatible triple and pin WASIX tooling explicitly.
    config = "wasm32-unknown-wasi";
    useLLVM = true;
    isWasix = true;
    # Rust builds for the fork's target; pkgsCross hosts the wasix rustPlatform
    # below (its default stdenv has a real libc, which the cargo hooks' tooling
    # needs — unlike the libc-less wasixcc profile stdenv). C/C++ ignore this.
    rust.rustcTarget = "wasm32-wasmer-wasi";
  };
  pkgsCross = import nixpkgs {
    inherit system crossSystem;
    config.allowUnsupportedSystem = true;
  };

  # The wasix rustPlatform: makeRustPlatform with a `cargo` that routes the build through
  # cargo-wasix, so buildRustPackage drives it normally. The Rust counterpart to
  # mk-wasix-stdenv — injected into each profile set by the overlay so wasix Rust crates
  # build transparently via rustPlatform.buildRustPackage, the way C/C++ build via the
  # wasixcc stdenv.
  wasixRustPlatform = import ./mk-wasix-rust-platform.nix {
    inherit lib pkgsCross;
    inherit (foundation) wasixRustToolchain cargoWasix;
    cargo = pkgs.cargo;
  };

  defaultProfileName = "exnrefEh";

  # ── Per-profile cross package sets ───────────────────────────────────────────
  # Each profile is a full nixpkgs cross set (like pkgsStatic) with the wasixcc
  # stdenv injected via replaceCrossStdenv + the wasix overlay; linked deps
  # auto-thread within a profile.
  profilesCfg = import ./profiles.nix;
  mkWasixStdenv = import ./mk-wasix-stdenv.nix {inherit lib foundation;};

  # Package names = the overlay's package set (flat files + dirs + trivial list).
  wasixPkgNames = import ./overlay/names.nix {inherit lib;};

  # preferredPackages: each package at its preferred profile. A package declares
  # that via passthru.wasix.preferredProfile, read here WITHOUT building it
  # (passthru is eval-only; default exnrefEh). Reached for non-linked / runtime-
  # invoked deps so the consumer gets the dep at the profile it supports (e.g.
  # bash -> off), regardless of the consumer's profile. Lazy / mutually recursive
  # with profileSets.
  preferredProfileOf = name:
    profileSets.${defaultProfileName}.${name}.passthru.wasix.preferredProfile or defaultProfileName;
  preferredPackages = lib.genAttrs wasixPkgNames (name: profileSets.${preferredProfileOf name}.${name});

  wasixOverlay = import ./overlay {
    inherit foundation nixpkgs preferredPackages wasixRustPlatform;
    rustSupportedVariants = foundation.wasixRustToolchain.supportedVariants;
  };
  mkWasixPkgs = import ./mk-wasix-pkgs.nix {inherit system nixpkgs mkWasixStdenv wasixOverlay;};
  profileSets = lib.mapAttrs (_: spec: mkWasixPkgs spec) profilesCfg.profiles;

  # ── toolchain: per-profile build environments ────────────────────────────────
  # `foundation` holds the flat, profile-independent compilers; this is the
  # per-profile layer built from them: each profile's `stdenv` (C/C++, the wasixcc
  # cc-wrapper from profileSets) and `rustPlatform` (Rust — real on the variants the
  # rust toolchain targets, marked-broken elsewhere by the overlay), plus the
  # dev-env shell fragments + ABI metadata the link/stdenv tests and devShell need.
  devEnvFor = import ./toolchain/dev-env.nix {inherit pkgs foundation;};
  toolchain =
    lib.mapAttrs (
      profileName: spec: let
        wasmExceptions = spec.wasmExceptions or null;
        pic = spec.wasmPic or false;
      in
        (devEnvFor {inherit wasmExceptions pic;})
        // {
          inherit profileName wasmExceptions pic;
          stdenv = profileSets.${profileName}.stdenv;
          rustPlatform = profileSets.${profileName}.rustPlatform;
          host = "wasm32-wasix";
          buildCc = "${pkgs.buildPackages.stdenv.cc}/bin/cc";
        }
    )
    profilesCfg.profiles;
  defaultToolchain = toolchain.${defaultProfileName};

  # Toolchain tests, attached as passthru.tests on the toolchain packages so the
  # flake collects them uniformly with the shipped-package tests. Built here (not
  # in the flake) because they need the per-profile toolchain + the wasmer
  # runtime: sysroot smoke tests (per ABI variant) on `sysroot`, and per-profile
  # end-to-end link + stdenv tests on `wasixcc`.
  mkTestGroup = import ./test-group.nix {inherit pkgs lib;};
  toolchainTestPkgs = {
    sysroot = foundation.sysroot.overrideAttrs (o: {
      passthru = (o.passthru or {}) // {tests = mkTestGroup "sysroot" foundation.tests;};
    });
    wasixcc = foundation.wasixcc.overrideAttrs (o: {
      passthru =
        (o.passthru or {})
        // {
          tests = mkTestGroup "wasixcc" (
            (lib.mapAttrs' (p: tc:
              lib.nameValuePair "link-${p}" (pkgs.callPackage ./toolchain/link-test.nix {
                wasmer = wasmerRuntime;
                toolchain = tc;
              }))
            toolchain)
            // (lib.mapAttrs' (p: tc:
              lib.nameValuePair "stdenv-${p}" (pkgs.callPackage ./toolchain/stdenv-test.nix {
                wasmer = wasmerRuntime;
                toolchain = tc;
              }))
            toolchain)
          );
        };
    });
    # Rust analogue of the link/stdenv tests: build a hello-world through the wasix
    # rustPlatform (the real consumer path) and run it under wasmer. Single test (Rust
    # only targets the eh variant), attached to the rust toolchain package.
    rust = foundation.wasixRustToolchain.overrideAttrs (o: {
      passthru =
        (o.passthru or {})
        // {
          tests = mkTestGroup "rust" {
            hello = pkgs.callPackage ./toolchain/rust-test.nix {
              rustPlatform = wasixRustPlatform;
              wasmer = wasmerRuntime;
            };
          };
        };
    });
  };

  # ── package matrices for CI / consumers ──────────────────────────────────────
  # The non-shipped overlay packages are the libraries; build them across the
  # non-off profiles (off has no PIC sysroot — it exists only for bash & its
  # linked readline/ncurses, drawn on demand via preferredPackages).
  nonOffProfileNames = lib.filter (n: n != "off") (lib.attrNames profilesCfg.profiles);
  libPkgNames = lib.filter (n: !(lib.elem n shippedCommands)) wasixPkgNames;
  libraryMatrix =
    lib.genAttrs nonOffProfileNames
    (profile:
      # Skip libs that mark themselves unsupported on this profile via meta.badPlatforms (e.g.
      # snappy at the PIC profiles — its -fno-exceptions can't combine with PIC under wasixcc). We
      # check badPlatforms directly rather than meta.availableOn so libs with merely unix-only
      # meta.platforms (which still build here under allowUnsupportedSystem) aren't dropped.
        lib.filterAttrs
        (_: drv: !(builtins.elem profileSets.${profile}.stdenv.hostPlatform.system (drv.meta.badPlatforms or [])))
        (lib.genAttrs libPkgNames (n: profileSets.${profile}.${n})));

  # The CLIs shipped as webc packages, by overlay attr-name. Each is built at its
  # preferred profile (bash -> off, rest -> default) via preferredPackages, then
  # the wasmer layer augments it with .webc (the webc package) + .tests.
  shippedCommands = [
    "grep"
    "sed"
    "find"
    "gzip"
    "tar"
    "jq"
    "less"
    "nano"
    "gettext"
    "ncurses-progs"
    "bash"
    "gitMinimal"
    "curl"
    "crabsay"
    "sd"
    "ripgrep"
    "python3"
  ];

  # ── python wheels ────────────────────────────────────────────────────────────
  # The shipped Python wheels (overlay/python-packages/wheels.nix), each the wasm
  # cross build of python3.pkgs.<attr> carrying an import smoke-test. cpython only
  # builds at the ehpic profile (ctypes/dl need PIC), so the wheels are anchored
  # there too — a single set, not a per-profile matrix.
  pythonWheels = import ./python-wheels.nix {
    inherit pkgs lib mkTestGroup;
    python3 = profileSets.ehpic.python3;
    wasmer = wasmerRuntime;
  };

  makeWasmerPackage = pkgs.callPackage ./wasmer/make-wasmer-package.nix {
    self = makeWasmerPackage;
    wasmer = wasmerRuntime;
  };

  wasmerLayer = import ./wasmer {
    inherit (pkgs) lib;
    inherit pkgs makeWasmerPackage preferredPackages shippedCommands;
    wasmer = wasmerRuntime;
    packagesDir = ./overlay/packages;
  };
  # shippedPackages.<name> = the wasm cross build (keyed by program name), each
  # carrying passthru.webc (the webc package) + passthru.tests.
  inherit (wasmerLayer) shippedPackages allWasmer;

  # All shipped .wasm binaries, collected from the leaves at their preferred
  # profiles (curl puts curl.wasm in its `bin` output, hence the per-pkg glob).
  allWasm = pkgs.runCommand "wasix-all-wasm" {} ''
    mkdir -p "$out/bin"
    ${lib.concatMapStringsSep "\n" (name: ''
      if [ -d "${shippedPackages.${name}}/bin" ]; then
        ${pkgs.findutils}/bin/find "${shippedPackages.${name}}/bin" -maxdepth 1 -type f -name '*.wasm' \
          -exec ${pkgs.coreutils}/bin/cp -f '{}' "$out/bin/" \;
      fi
    '') (builtins.attrNames shippedPackages)}
  '';
in {
  inherit pkgs pkgsCross defaultProfileName;
  inherit foundation toolchain profileSets preferredPackages allWasm allWasmer;
  inherit shippedCommands shippedPackages libraryMatrix toolchainTestPkgs;
  inherit pythonWheels;
}
