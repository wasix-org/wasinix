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
  products = import ./products;
  pkgs = import nixpkgs {
    inherit system;
    overlays = [
      (_: prev: {
        nix-update = prev.nix-update.overrideAttrs (old: {
          patches =
            (old.patches or [])
            ++ [
              ./nix-update-read-write-eval.patch
              ./nix-update-prefer-tag-over-rev.patch
              ./nix-update-revision.patch
            ];
        });
        # wasm-opt aborts on `!endMap.contains(span.end)` reading a `-g` module
        # whose legacy-EH try needs a wrapper block: the wrapper takes the end
        # location, the original keeps the start, and two spans end at 0.
        # Backport of binaryen#8944.
        binaryen = prev.binaryen.overrideAttrs (old: {
          patches = (old.patches or []) ++ [./binaryen-irbuilder-wrapper-block-spans.patch];
        });
      })
      (products.overlay {})
    ];
  };
  inherit (pkgs) lib;
  nixUpdate = pkgs.nix-update;
  referenceScanner = pkgs.callPackage ./lib/check-reference-scanner.nix {};
  wasixLib = import ./lib {
    inherit lib referenceScanner;
    snapshotZstd = pkgs.zstd;
  };
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
  crateEdits =
    import ./lib/crate-edits.nix {
      inherit pkgs;
      pins = builtins.fromJSON (builtins.readFile ./cargo-registry/crates.json);
    }
    ./lib/wasix-crate-patches;

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
  mkWasixStdenv = import ./set/stdenv.nix {
    inherit lib toolchain referenceScanner;
    snapshotZstd = pkgs.zstd;
  };

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
    wasixRunStub = wasixRun.stub;
    inherit (pkgs) nix-update-script;
  };
  productsOverlay = products.overlay {nativeNixUpdateScript = pkgs.nix-update-script;};
  mkWasixPkgs = import ./set/mk-pkgs.nix {
    inherit system nixpkgs mkWasixStdenv productsOverlay wasixOverlay;
  };
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

  # Shared product recipes built independently for the native host, never taken
  # from a cross set's buildPackages splice.
  nativePackages = lib.genAttrs products.names (name: pkgs.${name});

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
    tinygo = pkgs.wasix-tinygo.overrideAttrs (o: {
      passthru =
        (o.passthru or {})
        // {
          tests = mkTestGroup "tinygo" {
            hello = pkgs.callPackage ./toolchain/tests/tinygo-test.nix {
              tinygo = pkgs.wasix-tinygo;
              wasmer = wasmerRuntime;
            };
          };
        };
    });
    sysroot = toolchain.sysroot.overrideAttrs (o: {
      passthru = (o.passthru or {}) // {tests = mkTestGroup "sysroot" toolchain.tests;};
    });
    wasixcc = toolchain.wasixcc.overrideAttrs (o: {
      passthru =
        (o.passthru or {})
        // {
          repros =
            (o.passthru.repros or {})
            // {
              wide-arithmetic = pkgs.callPackage ./toolchain/tests/wide-arithmetic-repro.nix {
                toolchain = toolchainByProfile.exnrefEh;
                inherit (toolchain) wasixcc;
                inherit wasixRun;
              };
            };
          tests = mkTestGroup "wasixcc" (
            {
              relocatable = pkgs.callPackage ./toolchain/tests/relocatable-link-test.nix {
                toolchain = defaultToolchain;
              };
            }
            // (lib.mapAttrs' (p: tc:
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
            cargo-test = pkgs.callPackage ./toolchain/tests/rust-cargo-test.nix {
              rustPlatform = wasixRustPlatform;
              inherit wasixRun;
              inherit (toolchain) binaryen;
            };
          };
        };
    });
  };

  # ── emulated build-system checks ─────────────────────────────────────────────
  # wasix-run trampoline: `.stub` carries no wasmer and is safe to bake into
  # builds, `.run` pins the runtime for the check derivations, so a wasmer bump
  # never rebuilds the package set.
  wasixRun = import ./wasmer/wasix-run.nix {
    inherit pkgs;
    wasmer =
      if wasmerRuntime != null
      then wasmerRuntime
      else pkgs.wasmer;
  };
  emulatedChecks = import ./emulated-check.nix {
    inherit lib pkgs wasixRun;
  };
  linkSmoke = import ./link-smoke.nix {
    inherit lib pkgs wasixRun;
    helpers = wasixLib;
  };

  # Phase the package's declared suite (doCheck) runs in, or null: the value
  # feeds `checkFor`'s `phase` argument below, which wants a phase name
  # (python-wheels.nix's installCheck path feeds it "pythonCheckPhase" the
  # same way). Read via overrideAttrs: make-derivation rebinds the built value
  # to the cross-gated one, but the argument the package passed is still
  # visible there. Needs the `check` output (lib/check-output.nix); installCheck
  # suites go through python-wheels.nix.
  declaresCheck = drv:
    if !(drv ? check)
    then null
    else
      (drv.overrideAttrs (old: {
        passthru =
          (old.passthru or {})
          // {
            wasixCheckPhaseName =
              if (old.doCheck or false)
              then "checkPhase"
              else null;
          };
      }))
    .wasixCheckPhaseName;

  # Test producers compose only through the package-local namespace. `all`
  # and `names` are regenerated after every addition so they always cover
  # the current leaves.
  testLeavesOf = drv: removeAttrs ((drv.passthru or {}).tests or {}) ["all" "names"];
  withTest = groupName: testName: test: drv:
    drv.overrideAttrs (old: {
      passthru =
        (old.passthru or {})
        // {
          tests = mkTestGroup groupName ((testLeavesOf drv) // {${testName} = test;});
        };
    });

  # nixpkgs passthru.tests are native x86 suites, not tests of the cross build.
  withoutNativeTests = drv:
    if (drv.passthru or {}) ? tests
    then
      drv.overrideAttrs (old: {
        passthru = removeAttrs (old.passthru or {}) ["tests"];
      })
    else drv;

  # Replay only the package's declared upstream suite. Synthetic checks do not
  # participate in its detection, profile selection, or opt-out policy.
  withEmulatedCheck = profile: name: drv: let
    meta = wasixLib.wasixMetaOf drv;
    declared = meta.emulatedCheck or null;
    # emulatedCheck carries only what is not derivable (expectFail/broken,
    # timeout); `false` opts out.
    spec =
      if declared == null
      then {}
      else if declared == false
      then null
      else declared;
    profiles =
      if spec != null && spec ? profiles
      then spec.profiles
      else meta.supportedProfiles or [profile];
    checkPhaseName =
      if spec == null
      then null
      else let
        r = builtins.tryEval (declaresCheck drv);
      in
        if r.success
        then r.value
        else null;
    runHere = !(drv.meta.broken or false) && checkPhaseName != null && lib.elem profile profiles;
  in
    if !runHere
    then drv
    else
      withTest "${name}-${profile}" "upstream" (emulatedChecks.checkFor {
        inherit drv spec;
        phase = checkPhaseName;
        name = "${name}-check";
      })
      drv;

  # Independently attach the synthetic link probe. It neither substitutes for
  # nor implies the existence of an upstream suite.
  withLinkCheck = profile: name: drv: let
    runHere = !(drv.meta.broken or false) && linkSmoke.enabledFor drv;
  in
    if !runHere
    then drv
    else withTest "${name}-${profile}" "link" (linkSmoke.linkFor nixpkgsByProfile.${profile} drv) drv;

  # A package whose evaluation throws produces no CI jobs at all, which reads
  # exactly like "no suite"; no runtime guard can see that. Names come from the
  # overlay loader, independent of whether the packages evaluate.
  evalSanity = let
    broken = lib.concatMap (
      profile:
        lib.concatMap (
          name: let
            r = builtins.tryEval (
              let
                d = nixpkgsByProfile.${profile}.${name};
              in
                # meta.broken makes nixpkgs assert on drvPath by design, and a
                # profile the package does not claim is not a failure either.
                if wasixLib.supportedIn profile d && !(d.meta.broken or false)
                then builtins.seq d.drvPath "ok"
                else "skipped"
            );
          in
            lib.optional (!r.success) "${profile}.${name}"
        )
        wasixPkgNames
    ) (lib.attrNames profilesCfg.profiles);
  in
    pkgs.runCommand "wasix-eval-sanity" {} ''
      ${
        if broken == []
        then ''echo "all ${toString (builtins.length wasixPkgNames)} packages evaluate on every profile"''
        else ''
          echo "these packages fail to EVALUATE, so they produce no CI jobs at all:" >&2
          ${lib.concatMapStringsSep "\n" (b: ''echo "  ${b}" >&2'') broken}
          exit 1
        ''
      }
      touch "$out"
    '';

  # ── package matrices for CI / consumers ──────────────────────────────────────
  # Complete public view: every package under every supported profile.
  packagesByProfile =
    lib.genAttrs (lib.attrNames profilesCfg.profiles)
    (profile:
      lib.mapAttrs (name: drv:
        if lib.elem name shippedCommands
        then drv
        else withLinkCheck profile name (withEmulatedCheck profile name (withoutNativeTests drv)))
      (lib.filterAttrs
        (_: wasixLib.supportedIn profile)
        (lib.genAttrs wasixPkgNames (n: nixpkgsByProfile.${profile}.${n}))));

  # CI policy transposed into the same profile/package shape. This stays
  # separate from packagesByProfile so reducing coverage never hides a build.
  ciPackagesByProfile =
    lib.mapAttrs (
      profile: packages:
        lib.filterAttrs (_: drv: builtins.elem profile (wasixLib.ciProfilesOf drv)) packages
    )
    packagesByProfile;

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
      in
        abiCheck {
          name = profile;
          paths = lib.attrValues (notBroken ciPackagesByProfile.${profile});
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
  publicationRels = builtins.fromJSON (builtins.readFile ../rels.json);
  mkPythonWheels = pyKey: pyAttr: select: let
    wheels = import ./python-wheels.nix {
      inherit pkgs lib mkTestGroup select pyKey emulatedChecks;
      inherit (wasixLib.checkOutput) installCheckOutputArgsIf;
      python3 = nixpkgsByProfile.exnrefEhpic.${pyAttr};
      wasmer = wasmerRuntime;
      pythonWebc = preferredProfilePackagesWithWebc.${pyAttr}.webc;
    };
    withPublication = _: drv:
      drv.overrideAttrs (old: {
        passthru =
          (old.passthru or {})
          // {
            wasix =
              ((old.passthru or {}).wasix or {})
              // {
                publication = {
                  inherit (drv) version;
                  rel = (publicationRels."pythonRegistry.wheels.${drv.pname or drv.name}" or {}).${drv.version} or 1;
                };
              };
          };
      });
  in
    lib.mapAttrs withPublication wheels;
  # Import tests for the dependency closure: packages that ship in the registry
  # because a shipped wheel pulls them in, which the worklist never names.
  pythonClosureTests = let
    py = nixpkgsByProfile.exnrefEhpic.python314;
  in
    import ./python-closure-tests.nix {
      inherit lib;
      python3 = py;
      testLib = import ./python-test-lib.nix {
        inherit pkgs lib;
        python3 = py;
        pythonWebc = wasmerLayer.wasmerPackages.python314.webc;
        wasmer = wasmerRuntime;
      };
      wheelList = import ./overlay/python-packages/wheels.nix;
    };

  isNoarch = e: e.noarch or false;
  publishOnceWheelNames =
    map (e: e.attr)
    (lib.filter (e: e.publishOnce or false) (import ./overlay/python-packages/wheels.nix));
  pythonWheels = {
    noarch = mkPythonWheels "noarch" "python314" isNoarch;
    py313 = mkPythonWheels "py313" "python313" (e: !isNoarch e);
    py314 = mkPythonWheels "py314" "python314" (e: !isNoarch e);
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
    inherit pythonRegistry;
    # Shipped CLIs run only a declared emulatedCheck, never an auto-detected
    # one: they already carry curated suites or the liveness smoke, and their
    # build layouts do not fit the generic runner. Libraries keep the
    # auto-detection.
    emulatedChecksFor = drv: let
      spec = (wasixLib.wasixMetaOf drv).emulatedCheck or null;
    in
      if spec == null || spec == false
      then {}
      else {upstream = emulatedChecks.checkFor {inherit drv spec;};};
  };
  preferredProfilePackagesWithWebc = wasmerLayer.preferredProfilePackages;
  # Public package names and aliases; canonical-only consumers use the inventory.
  inherit (wasmerLayer) wasmerPackages wasmerPackageInventory allWasmerPackages libraryTestPkgs;

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
    pythonWebc = preferredProfilePackagesWithWebc.python3.shim;
  };
in {
  inherit pkgs pkgsCross nixUpdate defaultProfileName wasixPkgNames wasixRun;
  inherit nativePackages packagesByProfile ciPackagesByProfile;
  inherit toolchain toolchainByProfile nixpkgsByProfile allWasmerPackages;
  preferredProfilePackages = preferredProfilePackagesWithWebc;
  inherit shippedCommands wasmerPackages wasmerPackageInventory toolchainTestPkgs abiChecks evalSanity;
  inherit libraryTestPkgs;
  inherit pythonWheels pythonRegistry cargoRegistry pythonClosureTests;
}
