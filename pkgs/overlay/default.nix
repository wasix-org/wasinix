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

  wrapperFix = lib.optionalAttrs isWasixTarget {
    makeShellWrapper = prev.makeShellWrapper.overrideAttrs (_: {
      shell = "${final.buildPackages.bash}/bin/bash";
    });
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
    hp = prev.stdenv.hostPlatform;
    exc = hp.wasmExceptions or "no";
    pic = hp.wasmPic or false;
    variant =
      if exc == "no"
      then "off"
      else if exc == "yes"
      then
        (
          if pic
          then "exnrefEhpic"
          else "exnrefEh"
        )
      else
        (
          if pic
          then "ehpic"
          else "eh"
        );
    supported = lib.elem variant rustSupportedVariants;
  in {
    rustPlatform =
      if supported
      then wasixRustPlatform
      else
        wasixRustPlatform
        // {
          buildRustPackage = args:
            wasixRustPlatform.buildRustPackage (args
              // {
                meta =
                  (args.meta or {})
                  // {
                    broken = true;
                    badPlatforms = ["wasm32-wasi"];
                  };
              });
        };
  });

  packages =
    if !isWasixHost
    then {}
    else let
      helpers = import ./lib.nix {inherit lib;};
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
