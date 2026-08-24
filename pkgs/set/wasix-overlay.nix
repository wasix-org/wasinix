# WASIX-wide compiler, language, and build-stage replacements. Package
# adaptations are a separate overlay so this layer can precede registered units.
{
  toolchain,
  wasixRustPlatform,
  # Wasmer-free emulation trampoline, used wherever an
  # emulator path is baked into a build.
  wasixRunStub,
}: final: prev: let
  inherit (prev) lib;
  helpers = import ../lib {inherit lib;};

  # The per-profile toolchain members picked once, so no package file repeats it.
  profileToolchain = let
    profileName = helpers.profileOf prev.stdenv.hostPlatform;
  in
    toolchain
    // {
      flangRt = toolchain.flangRtByProfile.${profileName};
      openmp = toolchain.openmpByProfile.${profileName};
      wasixflang = toolchain.wasixflangByProfile.${profileName};
    };

  # Two gates (read prev.stdenv; gating on final.stdenv would be a fixpoint
  # cycle). Package overrides apply only when the HOST is wasix: overlays
  # otherwise hit every stage (including buildPackages), rebuilding the native
  # gcc/perl that link e.g. zlib. The wrapper fixes apply whenever the TARGET
  # is wasix, which also covers pkgsBuildHost (host x86_64, target wasm), the
  # stage wasix packages take those hooks from.
  isWasixHost = prev.stdenv.hostPlatform.isWasix or false;
  isWasixTarget = prev.stdenv.targetPlatform.isWasix or false;

  wrapperFix =
    lib.optionalAttrs isWasixTarget {
      # The stock hook bakes targetPackages.runtimeShell (the wasm bash,
      # unbuildable in non-off profiles) into its wrappers, so it fails to
      # build even when pulled transitively. A build-platform shebang is fine:
      # the wrappers we keep are dev scripts (freetype-config), never run on
      # wasm, and wrapProgram keeps working for nano/gzip/etc.
      makeShellWrapper = prev.makeShellWrapper.overrideAttrs (_: {
        shell = lib.getExe final.buildPackages.bash;
      });

      # nixpkgs' emulatorAvailable check evaluates `${pkgs.wasmtime}`, which in
      # this cross set is wasmtime cross-compiled to wasm32: meta-unsupported,
      # breaking eval of every meson wheel. Substitute a buildable
      # build-platform script so eval proceeds. Meson never runs it
      # (mesonEmulatorHook is no-op'd below), and nothing in a wasm sysroot
      # depends on wasmtime-the-package, so shadowing it is harmless.
      #
      # It is the wasix-run stub, not a wasmer: hostPlatform.emulator is
      # interpolated into build phases, and a real runtime there would put the
      # fast-moving wasmer input into package build closures.
      wasmtime = final.buildPackages.runCommand "wasmtime-wasix-run" {} ''
        mkdir -p "$out/bin"
        ln -s ${lib.getExe wasixRunStub} "$out/bin/wasmtime"
      '';

      # Do NOT wire an exe_wrapper into meson's cross file: the stock
      # mesonEmulatorHook makes meson run target wasm binaries at build time
      # via wasmer, which fails on JIT/exec-restricted remote builders
      # ("Executables created by c compiler ... are not runnable"). meson's
      # main cross file already sets needs_exe_wrapper=true for wasm, so with
      # no wrapper it cross-compiles without running target binaries;
      # numpy/contourpy/pandas/matplotlib don't need to (cpu-baseline=none).
      mesonEmulatorHook =
        final.buildPackages.makeSetupHook {name = "meson-emulator-hook-noop";}
        (final.buildPackages.writeText "meson-emulator-hook-noop.sh" ''
          # wasix: intentionally empty because target executables do not run during builds.
        '');

      # Point the cross set's top-level `cargo`/`rustc` (the cargo-wasix shim
      # and fork rustc) at the wasix toolchain. setuptools-rust/maturin
      # packages (bcrypt, cryptography, pydantic-core, ...) pull them as plain
      # nativeBuildInputs; nixpkgs' cross rustc wants
      # `targetPackages.stdenv.cc.libc`, null on the libc-less wasix stdenv,
      # so eval fails. Gated on isWasixTarget: these run on the build platform
      # and live in pkgsBuildHost. `rustPlatform.buildRustPackage` users
      # (sd/ripgrep) don't read these.
      inherit (wasixRustPlatform) cargo;
      inherit (wasixRustPlatform) rustc;

      # A Fortran recipe names its compiler `gfortran` and gcc has no wasm
      # backend, so the set's gfortran is wasixflang wrapped like any other
      # cc-wrapper compiler. langFortran pulls in fortran-hook.sh, which exports
      # FC, and that is how cmake and meson find it with no per-package flag.
      # isClang=false because the driver inspects its own argv, and a clang
      # wrapper collapses the command line into an @response-file it cannot read.
      # The target's profile, not the host's: this resolves in pkgsBuildHost.
      gfortran = final.targetPackages.stdenv.cc.override {
        cc = toolchain.wasixflangByProfile.${helpers.profileOf prev.stdenv.targetPlatform};
        isClang = false;
      };
    }
    # In the build stage (host x86, target wasm), python-rust build hooks are
    # spliced from `rustPlatform`. nixpkgs' maturinBuildHook targets stock
    # wasm32-wasip1 (no std in our toolchain), so swap in the wasix one (dl
    # target + rust-lld) for maturin wheels (pydantic-core/orjson). Only that
    # hook: replacing the whole rustPlatform would pull the wasix
    # cargoSetupHook, whose vendoring tools would cross-compile and fail.
    # Gated !isWasixHost so the wasm-host stage keeps the full
    # wasixRustPlatform below.
    // lib.optionalAttrs (isWasixTarget && !isWasixHost) {
      rustPlatform = prev.rustPlatform // {inherit (wasixRustPlatform) maturinBuildHook;};
    };

  # Replace rustPlatform with the from-source wasix one (set/rust-platform.nix)
  # so `rustPlatform.buildRustPackage` cross-builds to wasm32-wasmer-wasi with
  # no per-package plumbing. It carries its own clean cross set for the
  # cargo-hook tooling (the wasixcc stdenv is libc-less, so nixpkgs' cross
  # rustc can't build) while compiling with the fork rustc. Rust only targets
  # some profiles (eh, and ehpic when -dl builds); rust-platform.nix sets
  # passthru.wasix.supportedProfiles, and the package layer marks the rest
  # unsupported.
  rustSupport = lib.optionalAttrs isWasixHost {rustPlatform = wasixRustPlatform;};

  goSupport = lib.optionalAttrs isWasixHost {
    buildGoModule = final.callPackage ./tinygo-platform.nix {
      inherit (prev) buildGoModule;
      tinygo = toolchain.wasixTinyGo;
    };
  };

  # `final.haskellPackages`, like nixpkgs' top-level attr: the toolchain's base
  # wasi set plus the per-package overrides in ../wasix/haskell-packages (loaded like
  # this directory, the way python3.pkgs takes packageOverrides from ../python).
  haskellPackages = toolchain.haskell.packages.extend (import ../wasix/haskell-packages {
    callArgs = {
      inherit final prev helpers lib;
      toolchain = profileToolchain;
    };
  });

  perlPackages = final.perl.pkgs.overrideScope (import ../wasix/perl-packages {
    inherit final helpers wasixRunStub;
  });
in
  rustSupport
  // goSupport
  // wrapperFix
  // lib.optionalAttrs isWasixHost {
    inherit haskellPackages perlPackages;
    perl5Packages = perlPackages;
    # nixpkgs builds this by calling bash's expression again rather than
    # overriding the `bash` attr, so it would miss every wasix tweak and fail to
    # compile. It backs `runtimeShellPackage`, which any package wanting a
    # runtime shell pulls in. Same build as ours, minus readline.
    bashNonInteractive = final.bash.override {interactive = false;};
    # Opt-in setup hook: disables wasm-opt during configurePhase so a wasm-opt
    # failure on a throwaway conftest can't corrupt feature detection (e.g.
    # sqlite/libzip's libm checks).
    disableWasmOptInConfigureHook =
      final.buildPackages.makeSetupHook {
        name = "disable-wasm-opt-in-configure-hook";
      }
      (final.buildPackages.writeText "disable-wasm-opt-in-configure-hook.sh" ''
        _wasixWasmOptSaved=
        _disableWasmOptInConfigure() {
          _wasixWasmOptSaved="''${WASIXCC_RUN_WASM_OPT-}"
          export WASIXCC_RUN_WASM_OPT=no
        }
        _restoreWasmOptAfterConfigure() {
          if [ -n "$_wasixWasmOptSaved" ]; then
            export WASIXCC_RUN_WASM_OPT="$_wasixWasmOptSaved"
          else
            unset WASIXCC_RUN_WASM_OPT
          fi
        }
        preConfigureHooks+=(_disableWasmOptInConfigure)
        postConfigureHooks+=(_restoreWasmOptAfterConfigure)
      '');
  }
