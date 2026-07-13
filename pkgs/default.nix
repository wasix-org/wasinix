{
  system,
  nixpkgs,
  # wasmer runtime for the behavioural tests; null falls back to nixpkgs' wasmer.
  wasmerRuntime ? null,
  # ghc-wasm-meta bindist GHC, for toolchain.haskell.
  ghcWasm,
}: let
  pkgs = import nixpkgs {inherit system;};
  inherit (pkgs) lib;
  wasixLib = import ./lib {inherit lib;};
  toolchain = import ./toolchain {inherit pkgs ghcWasm;};

  # The wasix cross target. Defined here (not derived from a profile) so
  # pkgsCross can be built before the profiles, which consume it for their
  # cc-wrapper stdenvs.
  crossSystem = {
    # Keep nixpkgs parser-compatible triple and pin WASIX tooling explicitly.
    config = "wasm32-unknown-wasi";
    useLLVM = true;
    isWasix = true;
    # Rust builds for the fork's target. pkgsCross hosts the wasix rustPlatform:
    # its default stdenv has a real libc, which the cargo hooks' tooling needs
    # (the wasixcc profile stdenv is libc-less). C/C++ ignore this field.
    rust.rustcTarget = "wasm32-wasmer-wasi";
  };
  pkgsCross = import nixpkgs {
    inherit system crossSystem;
    config.allowUnsupportedSystem = true;
  };

  # makeRustPlatform with a cargo shim that routes builds through cargo-wasix.
  # The overlay injects it into each profile set so Rust crates build via
  # rustPlatform.buildRustPackage, like C/C++ do via the wasixcc stdenv.
  wasixRustPlatform = import ./set/rust-platform.nix {
    inherit lib pkgsCross;
    inherit (toolchain) wasixRustToolchain cargoWasix;
    cargo = pkgs.cargo;
  };

  defaultProfileName = "exnrefEh";

  # ── Per-profile cross package sets ───────────────────────────────────────────
  # Each profile is a full nixpkgs cross set (like pkgsStatic) with the wasixcc
  # stdenv injected via replaceCrossStdenv plus the wasix overlay; linked deps
  # resolve within the profile.
  profilesCfg = import ./profiles.nix;
  mkWasixStdenv = import ./set/stdenv.nix {inherit lib toolchain;};

  # Package names = the overlay's package set (flat files + dirs + trivial list),
  # enumerated eval-only via the shared loader so the two can't drift.
  wasixPkgNames =
    (wasixLib.loadPackageDir {
      dir = ./overlay/packages;
      trivial = import ./overlay/trivial.nix;
    }).names;

  # Each package at its preferred profile, read eval-only from passthru.wasix
  # (preferredProfile, or derived from supportedProfiles; see pkgs/lib). Used
  # for non-linked, runtime-invoked deps so e.g. bash resolves at "off"
  # regardless of the consumer's profile. Lazy, mutually recursive with nixpkgsByProfile.
  preferredProfileOf = name:
    wasixLib.preferredProfileOf nixpkgsByProfile.${defaultProfileName}.${name};
  preferredProfilePackages = lib.genAttrs wasixPkgNames (name: nixpkgsByProfile.${preferredProfileOf name}.${name});

  wasixOverlay = import ./overlay {
    inherit toolchain nixpkgs preferredProfilePackages wasixRustPlatform;
    inherit (pkgs) nix-update-script;
  };
  mkWasixPkgs = import ./set/mk-pkgs.nix {inherit system nixpkgs mkWasixStdenv wasixOverlay;};
  nixpkgsByProfile = lib.mapAttrs (_: spec: mkWasixPkgs spec) profilesCfg.profiles;

  # ── toolchainByProfile: per-profile build environments ────────────────────────────────
  # Per-profile layer over the profile-independent `toolchain`: each profile's
  # stdenv and rustPlatform (from nixpkgsByProfile), plus the dev-env shell fragments
  # and ABI metadata the link/stdenv tests and devShell need. Rust is only
  # supported on the profiles its toolchain targets (see pkgs/lib).
  devEnvFor = import ./toolchain/dev-env.nix {inherit pkgs toolchain;};
  toolchainByProfile =
    lib.mapAttrs (
      profileName: spec: let
        wasmExceptions = spec.wasmExceptions or null;
        pic = spec.wasmPic or false;
      in
        (devEnvFor {inherit wasmExceptions pic;})
        // {
          inherit profileName wasmExceptions pic;
          stdenv = nixpkgsByProfile.${profileName}.stdenv;
          rustPlatform = nixpkgsByProfile.${profileName}.rustPlatform;
          host = "wasm32-wasix";
          buildCc = "${pkgs.buildPackages.stdenv.cc}/bin/cc";
        }
    )
    profilesCfg.profiles;
  defaultToolchain = toolchainByProfile.${defaultProfileName};

  # Toolchain tests as passthru.tests, so the flake collects them like the
  # shipped-package tests: per-variant sysroot smoke tests on `sysroot`,
  # per-profile link + stdenv tests on `wasixcc`. Built here (not in the flake)
  # because they need the per-profile toolchain and the wasmer runtime.
  mkTestGroup = import ./lib/test-group.nix {
    inherit pkgs lib;
    inherit (wasixLib) posOf;
  };
  toolchainTestPkgs = {
    sysroot = toolchain.sysroot.overrideAttrs (o: {
      passthru = (o.passthru or {}) // {tests = mkTestGroup "sysroot" toolchain.tests;};
    });
    wasixcc = toolchain.wasixcc.overrideAttrs (o: {
      passthru =
        (o.passthru or {})
        // {
          tests = mkTestGroup "wasixcc" (
            (lib.mapAttrs' (p: tc:
              lib.nameValuePair "link-${p}" (pkgs.callPackage ./toolchain/tests/link-test.nix {
                wasmer = wasmerRuntime;
                toolchain = tc;
              }))
            toolchainByProfile)
            // (lib.mapAttrs' (p: tc:
              lib.nameValuePair "stdenv-${p}" (pkgs.callPackage ./toolchain/tests/stdenv-test.nix {
                wasmer = wasmerRuntime;
                toolchain = tc;
              }))
            toolchainByProfile)
          );
        };
    });
    # Rust analogue of the link/stdenv tests: build hello-world through the wasix
    # rustPlatform and run it under wasmer. Single test, since Rust only targets
    # the eh variant.
    rust = toolchain.wasixRustToolchain.overrideAttrs (o: {
      passthru =
        (o.passthru or {})
        // {
          tests = mkTestGroup "rust" {
            hello = pkgs.callPackage ./toolchain/tests/rust-test.nix {
              rustPlatform = wasixRustPlatform;
              wasmer = wasmerRuntime;
            };
          };
        };
    });
  };

  # ── package matrices for CI / consumers ──────────────────────────────────────
  # Libraries (the non-shipped overlay packages), built across all profiles.
  # A package that doesn't target a profile declares it via passthru.wasix.
  libPkgNames = lib.filter (n: !(lib.elem n shippedCommands)) wasixPkgNames;
  librariesByProfile =
    lib.genAttrs (lib.attrNames profilesCfg.profiles)
    (profile:
      # Skip libs whose passthru.wasix.supportedProfiles excludes this profile
      # (snappy at PIC profiles, rust packages outside eh/ehpic). Reads passthru,
      # not meta.availableOn, so libs with merely unix-only meta.platforms
      # (which still build under allowUnsupportedSystem) aren't dropped.
        lib.filterAttrs
        (_: wasixLib.supportedIn profile)
        (lib.genAttrs libPkgNames (n: nixpkgsByProfile.${profile}.${n})));

  # One ABI check per profile over that profile's whole column (matrix libs +
  # shipped packages preferring the profile, minus broken): objects must carry
  # the profile's exception-handling feature and PIC relocation flavor, linked
  # wasm the right module kind. Guards against flags moving a build to another
  # profile's sysroot. Asyncify expectations are per-package, checked in the
  # packages' own tests instead.
  abiCheck = pkgs.callPackage ./toolchain/tests/abi-check.nix {
    inherit (toolchain) wasixLlvm binaryen;
  };
  abiChecks =
    lib.mapAttrs (
      profile: enc: let
        notBroken = lib.filterAttrs (_: d: !(d.meta.broken or false));
        shippedHere =
          lib.filter
          (n: lib.elem n shippedCommands && preferredProfileOf n == profile)
          wasixPkgNames;
      in
        abiCheck {
          name = profile;
          paths =
            lib.attrValues (notBroken librariesByProfile.${profile})
            ++ map (n: preferredProfilePackages.${n}) shippedHere;
          inherit (enc) eh pic;
          dylink = enc.pic;
        }
    )
    profilesCfg.sysrootEncodings;

  # Packages shipped as webc, by overlay attr name: everything declaring
  # passthru.wasix.shipped. Built at their preferred profile (bash -> off,
  # rest -> default); the wasmer layer adds .pkg/.webc + .tests.
  shippedCommands =
    lib.filter
    (n: wasixLib.shippedOf nixpkgsByProfile.${defaultProfileName}.${n})
    wasixPkgNames;

  # ── python wheels ────────────────────────────────────────────────────────────
  # Shipped Python wheels (overlay/python-packages/wheels.nix): wasm cross builds
  # of python3.pkgs.<attr>, each with an import smoke-test. cpython needs PIC
  # (ctypes/dl) and the exnref EH encoding wasmer accepts, so the wheels are a
  # single set anchored at exnrefEhpic.
  pythonWheels = import ./python-wheels.nix {
    inherit pkgs lib mkTestGroup;
    python3 = nixpkgsByProfile.exnrefEhpic.python3;
    wasmer = wasmerRuntime;
    # the self-contained python webc; the import test runs on it with the wheel
    # copied into a plain dir and NO /nix/store mount, as `pip install` would.
    # Lazy: wasmerLayer doesn't depend on pythonWheels, so no eval cycle.
    pythonWebc = wasmerLayer.wasmerPackages.python.webc;
  };

  makeWasmerPackage = pkgs.callPackage ./wasmer/make-wasmer-package.nix {
    self = makeWasmerPackage;
    wasmer = wasmerRuntime;
    inherit (wasixLib) posOf;
  };

  wasmerLayer = import ./wasmer {
    inherit (pkgs) lib;
    inherit pkgs makeWasmerPackage preferredProfilePackages shippedCommands;
    inherit (wasixLib) posOf;
    crossPkgs = nixpkgsByProfile.${defaultProfileName};
    wasmer = wasmerRuntime;
    packagesDir = ./overlay/packages;
  };
  # wasmerPackages.<name> = the wasm cross build (keyed by program name), each
  # carrying passthru.pkg (the wasmer package), passthru.webc (its webc) + passthru.tests.
  inherit (wasmerLayer) wasmerPackages allWasmerPackages;

  # The shipped wheels (+ their transitive python deps) as a static PEP 503
  # "simple" index; tests run against the shipped python webc.
  pythonRegistry = import ./python-registry {
    inherit pkgs lib pythonWheels mkTestGroup;
    python3 = nixpkgsByProfile.exnrefEhpic.python3;
    inherit (wasmerLayer) testLib;
    pythonWebc = wasmerLayer.wrappedPackages.python;
  };

  # All shipped .wasm binaries, collected from the leaves at their preferred
  # profiles (curl puts curl.wasm in its `bin` output, hence the per-pkg glob).
  allWasm = pkgs.runCommand "wasix-all-wasm" {} ''
    mkdir -p "$out/bin"
    ${lib.concatMapStringsSep "\n" (name: ''
      if [ -d "${wasmerPackages.${name}}/bin" ]; then
        ${pkgs.findutils}/bin/find "${wasmerPackages.${name}}/bin" -maxdepth 1 -type f -name '*.wasm' \
          -exec ${pkgs.coreutils}/bin/cp -f '{}' "$out/bin/" \;
      fi
    '') (builtins.attrNames wasmerPackages)}
  '';
in {
  inherit pkgs pkgsCross defaultProfileName;
  inherit toolchain toolchainByProfile nixpkgsByProfile preferredProfilePackages allWasm allWasmerPackages;
  inherit shippedCommands wasmerPackages librariesByProfile toolchainTestPkgs abiChecks;
  inherit pythonWheels pythonRegistry;
}
