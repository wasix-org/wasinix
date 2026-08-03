{
  system,
  nixpkgs,
  # wasmer runtime for the behavioural tests; null falls back to nixpkgs' wasmer.
  wasmerRuntime ? null,
  # ghc-wasm-meta bindist GHC, for toolchain.haskell.
  ghcWasm,
  # Per-profile extra overlays, keyed by profile name. The spot-override seam
  # (see spot.nix): profile sets reference each other through
  # preferredProfilePackages, so a pin has to be injected here, where all of
  # them are built, rather than by extending one set from outside. Empty in
  # every normal eval; nothing that ships may set it.
  spotOverlays ? {},
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
  # crate-edits.nix view of wasix-crate-patches/, shared by the vendor-time
  # patching (rust-platform.nix) and the cargo-registry mint.
  crateEdits = import ./lib/crate-edits.nix {inherit pkgs;} ./lib/wasix-crate-patches;

  wasixRustPlatform = import ./set/rust-platform.nix {
    inherit lib pkgsCross crateEdits;
    inherit (toolchain) wasixRustToolchain wasixcc cargoWasix binaryen;
    cargo = pkgs.cargo;
  };

  defaultProfileName = "exnrefEh";

  # ── Per-profile cross package sets ───────────────────────────────────────────
  # Each profile is a full nixpkgs cross set (like pkgsStatic) with the wasixcc
  # stdenv injected via replaceCrossStdenv plus the wasix overlay; linked deps
  # resolve within the profile.
  profilesCfg = import ./profiles.nix;
  mkWasixStdenv = import ./set/stdenv.nix {inherit lib toolchain;};

  # Package names = the overlay's package set (flat files + dirs + trivial list
  # + registry-history versions), enumerated eval-only via the shared loader so
  # the two can't drift. Same history table the overlay builds from.
  packagesHistory = builtins.fromJSON (builtins.readFile ./overlay/packages/history.json);
  wasixPkgNames =
    (wasixLib.loadPackageDir {
      dir = ./overlay/packages;
      trivial = import ./overlay/trivial.nix;
      history = packagesHistory;
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
  nixpkgsByProfile = lib.mapAttrs (name: spec: mkWasixPkgs (spotOverlays.${name} or []) spec) profilesCfg.profiles;

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
            # shared libraries need PIC, so only the pic profiles can host it
            // (lib.mapAttrs' (p: tc:
              lib.nameValuePair "versioned-soname-${p}" (pkgs.callPackage ./toolchain/tests/versioned-soname-test.nix {
                wasmer = wasmerRuntime;
                toolchain = tc;
              }))
            (lib.filterAttrs (p: _: profilesCfg.profiles.${p}.wasmPic or false) toolchainByProfile))
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
  # Wheels split three ways: noarch (python-version-independent, e.g. a redistributed binary) built
  # ONCE on the default python; everything else per interpreter (cp313/cp314). Each import test runs
  # on its python webc. Lazy on wasmerLayer. Nothing is noarch yet; the split is ready for it.
  mkPythonWheels = pyKey: pyAttr: webcName: select:
    import ./python-wheels.nix {
      inherit pkgs lib mkTestGroup select pyKey;
      python3 = nixpkgsByProfile.exnrefEhpic.${pyAttr};
      wasmer = wasmerRuntime;
      pythonWebc = wasmerLayer.wasmerPackages.${webcName}.webc;
    };
  isNoarch = e: e.noarch or false;
  pythonWheels = {
    noarch = mkPythonWheels "noarch" "python314" "python3.14" isNoarch;
    py313 = mkPythonWheels "py313" "python313" "python3.13" (e: !isNoarch e);
    py314 = mkPythonWheels "py314" "python314" "python3.14" (e: !isNoarch e);
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
  # One merged PEP 503 index over BOTH python versions' wheels: a resolver picks the right file by
  # its cp313/cp314 tag, so the versions share an index (not split). e2e tests run on the default webc.
  pythonRegistry = import ./python-registry {
    inherit pkgs lib mkTestGroup;
    pythonSets = {
      # 314 carries the full set (noarch + its version-specific), so its closure has every
      # noarch + cp314 wheel; 313 adds only version-specific (cp313), pure deps dedupe.
      py314 = {
        python3 = nixpkgsByProfile.exnrefEhpic.python314;
        pythonWheels = pythonWheels.noarch // pythonWheels.py314;
      };
      py313 = {
        python3 = nixpkgsByProfile.exnrefEhpic.python313;
        pythonWheels = pythonWheels.py313;
      };
    };
    inherit (wasmerLayer) testLib;
    # default python interpreter + its webc, both from the top-level `python3`.
    python3 = nixpkgsByProfile.exnrefEhpic.python3;
    pythonWebc = wasmerLayer.wasmerPackages.python.shim;
  };
in {
  inherit pkgs pkgsCross defaultProfileName wasixPkgNames;
  inherit toolchain toolchainByProfile nixpkgsByProfile preferredProfilePackages allWasmerPackages;
  inherit shippedCommands wasmerPackages librariesByProfile toolchainTestPkgs abiChecks;
  inherit pythonWheels pythonRegistry;
}
