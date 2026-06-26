{
  system,
  nixpkgs,
  # the wasmer runtime used to run behavioural tests (passthru.tests on the webc
  # packages). A flake-level input; null falls back to nixpkgs' wasmer.
  wasmerRuntime ? null,
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

  defaultProfileName = "exnrefEh";

  # ── Per-profile cross package sets ───────────────────────────────────────────
  # Each profile is a full nixpkgs cross set (like pkgsStatic) with the wasixcc
  # stdenv injected via replaceCrossStdenv + the wasix overlay; linked deps
  # auto-thread within a profile.
  profilesCfg = import ./profiles.nix;
  mkWasixStdenv = import ./mk-wasix-stdenv.nix {inherit lib toolchainPkgs;};

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

  wasixOverlay = import ./overlay {inherit toolchainPkgs nixpkgs preferredPackages;};
  mkWasixPkgs = import ./mk-wasix-pkgs.nix {inherit system nixpkgs mkWasixStdenv wasixOverlay;};
  profileSets = lib.mapAttrs (_: spec: mkWasixPkgs spec) profilesCfg.profiles;

  # ── toolchains: per-profile toolchain handle ─────────────────────────────────
  # The per-package cross stdenv lives in profileSets (via mk-wasix-stdenv); this
  # re-exposes it alongside the toolchain tools + the dev-env shell fragments, for
  # the consumers that drive wasixcc outside a package build: the link/stdenv
  # tests and the devShell.
  devEnvFor = import ./toolchain/dev-env.nix {inherit pkgs toolchainPkgs;};
  toolchains =
    lib.mapAttrs (
      profileName: spec: let
        wasmExceptions = spec.wasmExceptions or null;
        pic = spec.wasmPic or false;
      in
        toolchainPkgs
        // (devEnvFor {inherit wasmExceptions pic;})
        // {
          inherit profileName wasmExceptions pic;
          stdenv = profileSets.${profileName}.stdenv;
          host = "wasm32-wasix";
          buildCc = "${pkgs.buildPackages.stdenv.cc}/bin/cc";
        }
    )
    profilesCfg.profiles;
  defaultToolchain = toolchains.${defaultProfileName};

  # Toolchain tests, attached as passthru.tests on the toolchain packages so the
  # flake collects them uniformly with the shipped-package tests. Built here (not
  # in the flake) because they need the per-profile toolchains + the wasmer
  # runtime: sysroot smoke tests (per ABI variant) on `sysroot`, and per-profile
  # end-to-end link + stdenv tests on `wasixcc`.
  mkTestGroup = import ./test-group.nix {inherit pkgs lib;};
  toolchainTestPkgs = {
    sysroot = toolchainPkgs.sysroot.overrideAttrs (o: {
      passthru = (o.passthru or {}) // {tests = mkTestGroup "sysroot" toolchainPkgs.tests;};
    });
    wasixcc = defaultToolchain.wasixcc.overrideAttrs (o: {
      passthru =
        (o.passthru or {})
        // {
          tests = mkTestGroup "wasixcc" (
            (lib.mapAttrs' (p: tc:
              lib.nameValuePair "link-${p}" (pkgs.callPackage ./toolchain/link-test.nix {
                wasmer = wasmerRuntime;
                toolchain = tc;
              }))
            toolchains)
            // (lib.mapAttrs' (p: tc:
              lib.nameValuePair "stdenv-${p}" (pkgs.callPackage ./toolchain/stdenv-test.nix {
                wasmer = wasmerRuntime;
                toolchain = tc;
              }))
            toolchains)
          );
        };
    });
  };

  # crabsay is Rust/cargoWasix (builds on the build platform, ignores the cross
  # stdenv), so it lives outside the overlay.
  crabsay = pkgs.callPackage ./crabsay.nix {cargoWasix = toolchainPkgs.cargoWasix;};

  # ── package matrices for CI / consumers ──────────────────────────────────────
  # The non-shipped overlay packages are the libraries; build them across the
  # non-off profiles (off has no PIC sysroot — it exists only for bash & its
  # linked readline/ncurses, drawn on demand via preferredPackages).
  nonOffProfileNames = lib.filter (n: n != "off") (lib.attrNames profilesCfg.profiles);
  libPkgNames = lib.filter (n: !(lib.elem n shippedCommands)) wasixPkgNames;
  libraryMatrix =
    lib.genAttrs nonOffProfileNames
    (profile: lib.genAttrs libPkgNames (n: profileSets.${profile}.${n}));

  # The CLIs shipped as webc packages, by overlay attr-name. Each is built at its
  # preferred profile (bash -> off, rest -> default) via preferredPackages, then
  # the wasmer layer augments it with .webc (the webc package) + .tests.
  shippedCommands = [
    "grep"
    "sed"
    "find"
    "gzip"
    "tar"
    "less"
    "nano"
    "gettext"
    "ncurses-progs"
    "bash"
    "gitMinimal"
    "curl"
  ];

  makeWasmerPackage = pkgs.callPackage ./wasmer/make-wasmer-package.nix {};

  wasmerLayer = import ./wasmer {
    inherit (pkgs) lib;
    inherit pkgs makeWasmerPackage preferredPackages shippedCommands;
    wasmer = wasmerRuntime;
    packagesDir = ./overlay/packages;
    extraShipped = {inherit crabsay;};
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
  inherit toolchainPkgs toolchains profileSets preferredPackages crabsay allWasm allWasmer;
  inherit shippedCommands shippedPackages libraryMatrix toolchainTestPkgs;
}
