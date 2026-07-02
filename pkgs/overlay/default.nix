# The wasix package overlay. Auto-imports every overlay/packages/<name>.nix and
# merges it into the profile's cross set.
#
# Because the stdenv (replaceCrossStdenv) already builds with wasixcc and
# auto-threads linked deps, each package file is just `prev.X` + tweaks — no
# stdenv override, no manual `self.X` dependency threading.
#
# Each packages/<name>.nix is a function taking:
#   { final, prev, helpers, foundation, preferredPackages, nixpkgs }
# and returning the wasix derivation. Use `final.<lib>` for linked deps
# (same-profile, auto-threaded) and `preferredPackages.<tool>` for non-linked /
# runtime-invoked deps (resolved to that tool's preferred profile).
{
  foundation,
  nixpkgs,
  preferredPackages,
  wasixRustPlatform,
  # ABI variants the wasix rust toolchain can target (e.g. ["eh"]); Rust packages
  # in any other profile are marked broken.
  rustSupportedVariants,
}: final: prev: let
  lib = prev.lib;
  helpers = import ./lib.nix {inherit lib;};
  # Two independent gates (read prev.stdenv, not final.stdenv — gating the
  # overlay's attr set on `final` would be a fixpoint cycle):
  #
  # - package overrides apply only when the HOST is wasix. Overlays otherwise
  #   apply to every stage (incl. buildPackages); overriding e.g. zlib there
  #   would rebuild the native gcc/perl that link it.
  # - the make-shell-wrapper-hook fix applies whenever the TARGET is wasix —
  #   which also catches pkgsBuildHost (host = x86_64, target = wasm), the stage
  #   wasix packages actually draw the hook from. The hook bakes
  #   targetPackages.runtimeShell (the wasm bash, unbuildable in non-off
  #   profiles) into its wrappers, so it fails to build even when only pulled
  #   transitively. Point its shell at the build-platform bash: the wrappers we
  #   keep are dev scripts (freetype-config), never the wasm runtime, so a
  #   native shebang is harmless — and wrapProgram works for nano/gzip/etc.
  isWasixHost = prev.stdenv.hostPlatform.isWasix or false;
  isWasixTarget = prev.stdenv.targetPlatform.isWasix or false;

  wrapperFix =
    lib.optionalAttrs isWasixTarget {
      makeShellWrapper = prev.makeShellWrapper.overrideAttrs (_: {
        shell = "${final.buildPackages.bash}/bin/bash";
      });

      # nixpkgs' emulatorAvailable check evaluates the platform emulator
      # (`selectEmulator` → `${pkgs.wasmtime}/bin/wasmtime`); with pkgs the wasix cross set
      # that wasmtime is cross-compiled to wasm32 — nonsensical and meta-unsupported on
      # wasm32-wasi, so it breaks the eval of every meson wheel. Give it a buildable
      # build-platform stand-in so emulatorAvailable is true and eval proceeds. This is only
      # to satisfy the availability check — meson never actually calls it, because
      # mesonEmulatorHook is no-op'd below. (This shadows wasmtime-the-package in the wasix
      # cross set, but nothing in a wasm sysroot depends on it, so that's harmless.)
      wasmtime = final.buildPackages.writeShellScriptBin "wasmtime" ''
        exec ${final.buildPackages.wasmer}/bin/wasmer run "$1" -- "''${@:2}"
      '';

      # Do NOT wire an exe_wrapper into meson's cross file. The stock mesonEmulatorHook adds
      # `--cross-file=<exe_wrapper=emulator>`, making meson RUN target wasm binaries at build
      # time (compiler sanity check, run-checks) via the emulator. That emulator (wasmer)
      # can't execute in every build sandbox — on JIT/exec-memory-restricted remote builders
      # it fails with "Executables created by c compiler … are not runnable", so the meson
      # wheels build locally but not on such a builder. meson's MAIN cross file already sets
      # needs_exe_wrapper=true for wasm, so with no wrapper it cross-compiles without running
      # target binaries. numpy/contourpy/pandas/matplotlib don't need to (cpu-baseline=none).
      mesonEmulatorHook =
        final.buildPackages.makeSetupHook {name = "meson-emulator-hook-noop";}
        (final.buildPackages.writeText "meson-emulator-hook-noop.sh" ''
          # wasix: intentionally empty — no meson exe_wrapper (see overlay/default.nix).
        '');

      # Point the cross set's top-level `cargo`/`rustc` at the wasix toolchain. The
      # python-rust path (setuptools-rust / maturin: bcrypt, cryptography, pydantic-core,
      # …) pulls `cargo`/`rustc` as plain nativeBuildInputs; left as nixpkgs' defaults
      # those are the cross nixpkgs rustc 1.95, whose rustc.nix wants
      # `targetPackages.stdenv.cc.libc` — null on the libc-less wasix stdenv → eval error.
      # Hand over our cargo-wasix shim + fork rustc. Gated isWasixTarget (not isWasixHost):
      # these run on the build platform and *target* wasm, so they live in the
      # pkgsBuildHost stage. Packages driven via `rustPlatform.buildRustPackage`
      # (sd/ripgrep) don't read these, so they're unaffected.
      cargo = wasixRustPlatform.cargo;
      rustc = wasixRustPlatform.rustc;
    }
    # In the PURE build stage (host = x86, target = wasm), the python-rust build hooks are
    # spliced from `rustPlatform`. nixpkgs' maturinBuildHook targets stock wasm32-wasip1
    # (no std in our toolchain), so swap in the wasix one (dl target + rust-lld linker) for
    # maturin wheels (pydantic-core/orjson). Swap ONLY that hook — replacing the whole
    # rustPlatform would also pull the wasix cargoSetupHook, whose vendoring tools
    # (diffutils/coreutils/…) would cross-compile and fail. Gated !isWasixHost so the
    # wasm-host stage keeps rustSupport's broken-variant marking.
    // lib.optionalAttrs (isWasixTarget && !isWasixHost) {
      rustPlatform = prev.rustPlatform // {inherit (wasixRustPlatform) maturinBuildHook;};
    };

  # Make Rust transparent here, the same way C/C++ is: replace rustPlatform with the
  # from-source wasix one (mk-wasix-rust-platform.nix), so `rustPlatform.buildRustPackage`
  # cross-builds to wasm32-wasmer-wasi with no per-package plumbing. It carries its own
  # clean cross set for the cargo-hook tooling (the wasixcc stdenv here is libc-less, so
  # nixpkgs' own cross rustc can't build), while compiling with the fork rustc.
  #
  # Rust only targets some ABI variants (eh, and ehpic when -dl builds). In the others
  # (off/exnref*) there's no std, so mark Rust packages broken — a clear, CI-graceful
  # error (vs a missing rustPlatform). The variant name is derived from this profile's
  # EH/PIC platform fields.
  rustSupport = lib.optionalAttrs isWasixHost (let
    supported = lib.elem (helpers.variantOf prev.stdenv.hostPlatform) rustSupportedVariants;
  in {
    rustPlatform =
      if supported
      then wasixRustPlatform
      else
        wasixRustPlatform
        // {
          # Accept both buildRustPackage forms (attrset or finalAttrs: function),
          # like the real wrapper — resolve, then force meta.broken.
          buildRustPackage = args:
            wasixRustPlatform.buildRustPackage (
              finalAttrs: let
                a =
                  if builtins.isFunction args
                  then args finalAttrs
                  else args;
              in
                a
                // {
                  meta =
                    (a.meta or {})
                    // {
                      broken = true;
                      badPlatforms = ["wasm32-wasi"];
                    };
                }
            );
        };
  });

  packages =
    if !isWasixHost
    then {}
    else let
      pkgDir = ./packages;
      entries = builtins.readDir pkgDir;
      # A package is either a flat packages/<name>.nix or a packages/<name>/ dir
      # (package.nix + patches/tests/aux). Trivial ones (no tweaks) are a list.
      fileNames =
        map (lib.removeSuffix ".nix")
        (lib.attrNames (lib.filterAttrs (n: t: t == "regular" && lib.hasSuffix ".nix" n) entries));
      dirNames = lib.attrNames (lib.filterAttrs (_: t: t == "directory") entries);
      callArgs = {inherit final prev helpers foundation preferredPackages nixpkgs;};
    in
      (lib.genAttrs (import ./trivial.nix) (n: helpers.libTweaks {} prev.${n}))
      // (lib.genAttrs fileNames (n: import (pkgDir + "/${n}.nix") callArgs))
      // (lib.genAttrs dirNames (n: import (pkgDir + "/${n}/package.nix") callArgs));
in
  packages
  // rustSupport
  // wrapperFix
  // lib.optionalAttrs isWasixHost {
    # Opt-in setup hook (added to a package's nativeBuildInputs): forces wasm-opt
    # off during configurePhase, so a wasm-opt failure on a throwaway conftest
    # can't corrupt feature detection (e.g. sqlite/libzip's libm checks). wasm-opt
    # is on by default; this is only for the few packages whose conftests trip it.
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
