{
  system,
  nixpkgs,
  # wasmer runtime for the behavioural tests; null falls back to nixpkgs' wasmer.
  wasmerRuntime ? null,
  # ghc-wasm-meta bindist GHC, for toolchain.haskell.
  ghcWasm,
  # The spot-override seam (spot.nix): profile sets reference each other through
  # preferredProfilePackages, so a pin must be injected here, where all of them
  # are built. Empty in every normal eval; nothing that ships may set it.
  spotOverlays ? {},
}: let
  pkgs = import nixpkgs {
    inherit system;
    overlays = [
      (_: prev: {
        nix-update = prev.nix-update.overrideAttrs (old: {
          patches = (old.patches or []) ++ [./nix-update-read-write-eval.patch];
        });
      })
    ];
  };
  inherit (pkgs) lib;
  nixUpdate = pkgs.nix-update;
  wasixLib = import ./lib {inherit lib;};
  wasmerDependencies = import ./wasmer/dependencies.nix {inherit lib;};
  toolchain = import ./toolchain {inherit pkgs ghcWasm;};

  # Defined here, not derived from a profile, so pkgsCross can be built before the
  # profiles, which consume it for their cc-wrapper stdenvs.
  crossSystem = {
    config = "wasm32-unknown-wasi"; # nixpkgs' triple parser rejects -wasix
    useLLVM = true;
    isWasix = true;
    # Rust only. pkgsCross hosts the wasix rustPlatform, whose cargo hooks need a
    # stdenv with a real libc (the wasixcc profile stdenv is libc-less).
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
  # Each profile is a full nixpkgs cross set with the wasixcc stdenv injected via
  # replaceCrossStdenv plus the wasix overlay; linked deps resolve within the profile.
  profilesCfg = import ./profiles.nix;
  mkWasixStdenv = import ./set/stdenv.nix {inherit lib toolchain;};

  # Enumerated eval-only through the same loader and history table the overlay
  # builds from, so the two can't drift.
  packagesHistory = builtins.fromJSON (builtins.readFile ./overlay/packages/history.json);
  wasixPkgNames =
    (wasixLib.loadPackageDir {
      dir = ./overlay/packages;
      trivial = import ./overlay/trivial.nix;
      history = packagesHistory;
    }).names;

  # For non-linked, runtime-invoked deps, so e.g. bash resolves at "off" whatever
  # the consumer's profile. Lazy, mutually recursive with nixpkgsByProfile.
  preferredProfileOf = name:
    wasixLib.preferredProfileOf nixpkgsByProfile.${defaultProfileName}.${name};
  preferredProfilePackages = lib.genAttrs wasixPkgNames (name: nixpkgsByProfile.${preferredProfileOf name}.${name});

  wasixOverlay = import ./overlay {
    inherit toolchain nixpkgs preferredProfilePackages wasixRustPlatform wasmerDependencies;
    inherit (pkgs) nix-update-script;
  };
  mkWasixPkgs = import ./set/mk-pkgs.nix {inherit system nixpkgs mkWasixStdenv wasixOverlay;};
  nixpkgsByProfile = lib.mapAttrs (name: spec: mkWasixPkgs (spotOverlays.${name} or []) spec) profilesCfg.profiles;

  # ── toolchainByProfile: per-profile build environments ────────────────────────────────
  # Per-profile layer over the profile-independent `toolchain`: each profile's
  # stdenv and rustPlatform, plus the dev-env fragments the tests and devShell need.
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
          inherit (toolchain.variants.${profileName}) sysroot libc compiler-rt libcxx flangRt openmp;
          wasixflang = toolchain.wasixflangByProfile.${profileName};
          stdenv = nixpkgsByProfile.${profileName}.stdenv;
          rustPlatform = nixpkgsByProfile.${profileName}.rustPlatform;
          host = "wasm32-wasix";
          buildCc = "${pkgs.buildPackages.stdenv.cc}/bin/cc";
        }
    )
    profilesCfg.profiles;
  defaultToolchain = toolchainByProfile.${defaultProfileName};

  # Profiles whose executables wasmer can execute, for the compile+link+run tests:
  # everything except legacy EH, whose `try` opcode wasmer has no feature flag for.
  # Same gate link-test.nix and openmp-test.nix apply internally.
  runnableProfiles = lib.filterAttrs (_: tc: tc.wasmExceptions != "legacy") toolchainByProfile;

  # Toolchain tests as passthru.tests, so the flake collects them like the shipped
  # ones. Built here: they need the per-profile toolchain and the wasmer runtime.
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
    # compile+link+run a tiny .f90 through flang + the cross-built flang-rt.
    flangRt = defaultToolchain.flangRt.overrideAttrs (o: {
      passthru =
        (o.passthru or {})
        // {
          tests = mkTestGroup "flangRt" (
            lib.mapAttrs' (p: tc:
              lib.nameValuePair "hello-${p}" (pkgs.callPackage ./toolchain/tests/flang-rt-test.nix {
                wasmer = wasmerRuntime;
                toolchain = tc;
                wasixflang = tc.wasixflang;
              }))
            runnableProfiles
          );
        };
    });
    # compile+link a `#pragma omp parallel` C program against the cross-built libomp
    # on every profile; the test itself runs it where wasmer can execute the module.
    openmp = defaultToolchain.openmp.overrideAttrs (o: {
      passthru =
        (o.passthru or {})
        // {
          tests = mkTestGroup "openmp" (
            lib.mapAttrs' (p: tc:
              lib.nameValuePair "hello-${p}" (pkgs.callPackage ./toolchain/tests/openmp-test.nix {
                wasmer = wasmerRuntime;
                toolchain = tc;
                openmp = tc.openmp;
              }))
            toolchainByProfile
          );
        };
    });
    # Single test: Rust only targets the eh variant.
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
  libPkgNames = lib.filter (n: !(lib.elem n shippedCommands)) wasixPkgNames;
  librariesByProfile =
    lib.genAttrs (lib.attrNames profilesCfg.profiles)
    (profile:
      # Reads passthru, not meta.availableOn, so libs whose meta.platforms is
      # merely unix-only are kept.
        lib.filterAttrs
        (_: wasixLib.supportedIn profile)
        (lib.genAttrs libPkgNames (n: nixpkgsByProfile.${profile}.${n})));

  # One check per profile over that profile's whole column: objects must carry the
  # profile's exception-handling feature and PIC relocation flavor, guarding against
  # flags moving a build onto another profile's sysroot.
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

  # Everything declaring passthru.wasix.shipped, at its preferred profile; the
  # wasmer layer adds .pkg/.webc + .tests.
  shippedCommands =
    lib.filter
    (n: wasixLib.shippedOf nixpkgsByProfile.${defaultProfileName}.${n})
    wasixPkgNames;

  # ── python wheels ────────────────────────────────────────────────────────────
  # Shipped Python wheels (overlay/python-packages/wheels.nix). cpython needs PIC
  # (ctypes/dl) and the exnref EH encoding wasmer accepts, so the wheels are one set
  # anchored at exnrefEhpic. noarch builds once, everything else per interpreter.
  mkPythonWheels = pyKey: pyAttr: webcName: select:
    import ./python-wheels.nix {
      inherit pkgs lib mkTestGroup select pyKey;
      python3 = nixpkgsByProfile.exnrefEhpic.${pyAttr};
      wasmer = wasmerRuntime;
      pythonWebc = wasmerLayer.wasmerPackages.${webcName}.webc;
    };
  isNoarch = e: e.noarch or false;
  publishOnceWheelNames =
    map (e: e.attr)
    (lib.filter (e: e.publishOnce or false) (import ./overlay/python-packages/wheels.nix));
  pythonWheels = {
    noarch = mkPythonWheels "noarch" "python314" "python3.14" isNoarch;
    py313 = mkPythonWheels "py313" "python313" "python3.13" (e: !isNoarch e);
    py314 = mkPythonWheels "py314" "python314" "python3.14" (e: !isNoarch e);
  };

  # The overlay cargo registry: the minted +wasix.N payload and its checks. The
  # server itself ships as the overlay package wasmerPackages.wasix-cargo-registry
  # (only ever wasm on Edge); its end-to-end serve check lives with that package
  # (overlay/packages/cargo-registry/tests), and the serve app runs the same wasm.
  cargoRegistry = import ./cargo-registry {
    inherit pkgs lib mkTestGroup crateEdits;
  };

  makeWasmerPackage = pkgs.callPackage ./wasmer/make-wasmer-package.nix {
    self = makeWasmerPackage;
    wasmer = wasmerRuntime;
    inherit wasmerDependencies;
    inherit (wasixLib) posOf;
  };

  wasmerLayer = import ./wasmer {
    inherit (pkgs) lib;
    inherit pkgs makeWasmerPackage preferredProfilePackages shippedCommands;
    inherit (wasixLib) posOf;
    crossPkgs = nixpkgsByProfile.${defaultProfileName};
    # for tests whose subject is PIC-only
    crossPkgsPic = nixpkgsByProfile.exnrefEhpic;
    wasmer = wasmerRuntime;
    packagesDir = ./overlay/packages;
  };
  # keyed by program name, each carrying passthru.pkg / .webc / .tests
  inherit (wasmerLayer) wasmerPackages allWasmerPackages libraryTestPkgs;

  # The shipped wheels plus their transitive deps as one static PEP 503 index over
  # both interpreters: a resolver picks the right file by its cp313/cp314 tag.
  pythonRegistry = import ./python-registry {
    inherit pkgs lib mkTestGroup;
    pythonSets = {
      # 314's closure covers every noarch + cp314 wheel; 313 adds only cp313.
      py314 = {
        python3 = nixpkgsByProfile.exnrefEhpic.python314;
        pythonWheels = pythonWheels.noarch // pythonWheels.py314;
      };
      py313 = {
        python3 = nixpkgsByProfile.exnrefEhpic.python313;
        pythonWheels = pythonWheels.py313;
        omitFromRegistry = publishOnceWheelNames;
      };
    };
    inherit (wasmerLayer) testLib;
    # default python interpreter + its webc, both from the top-level `python3`.
    python3 = nixpkgsByProfile.exnrefEhpic.python3;
    pythonWebc = wasmerLayer.wasmerPackages.python.shim;
  };
in {
  inherit pkgs pkgsCross nixUpdate defaultProfileName wasixPkgNames;
  inherit toolchain toolchainByProfile nixpkgsByProfile preferredProfilePackages allWasmerPackages;
  inherit shippedCommands wasmerPackages librariesByProfile toolchainTestPkgs abiChecks;
  inherit libraryTestPkgs;
  inherit pythonWheels pythonRegistry cargoRegistry;
}
