# nixpkgs haskellPackages driving ghc-wasm-meta's prebuilt wasm32-wasi GHC.
# Exposes `packages`, a haskell package set carrying the global wasm build config
# (no per-package patches; those belong to the consumer). TemplateHaskell works
# because wasm32-wasi runs the splice interpreter under node; the from-source
# wasix GHC can't (node can't host a wasix interpreter), which is why it's separate.
{pkgs}: let
  # allowUnsupportedSystem: nixpkgs marks most of haskellPackages unsupported on wasm.
  cross = import pkgs.path {
    system = "x86_64-linux";
    config.allowUnsupportedSystem = true;
    crossSystem = {
      config = "wasm32-unknown-wasi";
      useLLVM = true;
    };
  };

  wrappedGhc = pkgs.wasi-ghc;
  inherit (wrappedGhc.passthru) nodejs wasiSdk;

  # The wasm build config applied to every package, via the set's mkDerivation.
  # Per-package fixes are the consumer's job, not the toolchain's.
  packages = (cross.haskell.packages.ghc9123.override {ghc = wrappedGhc;}).extend (_final: prev: {
    mkDerivation = args:
      prev.mkDerivation (args
        // {
          # nixpkgs' iserv-proxy TH needs network/getaddrinfo (absent on wasi);
          # disable it so GHC's own dyld+node TH runs.
          enableExternalInterpreter = false;
          enableLibraryProfiling = false;
          # wasm strip is unsupported (crashes); wasm-opt is the real size pass.
          dontStrip = true;
          # gates the generic-builder fixup that points each package conf's
          # dynamic-library-dirs at the .so (so the dyld finds it).
          enableSharedLibraries = true;
          # nixpkgs appends a trailing --disable-shared on wasm and cabal is
          # last-wins, so re-append --enable-shared after it to get the .so.
          preConfigure =
            (args.preConfigure or "")
            + ''
              configureFlags="$configureFlags --enable-shared"
            '';
          doHaddock = false;
          # TH runs under node; the bindist pins one that works (nixpkgs' newer
          # node crashes the dyld on splices that load many modules).
          buildTools = (args.buildTools or []) ++ [nodejs];
          configureFlags =
            (args.configureFlags or [])
            ++ [
              # Use the bindist's LLVM-19 toolchain, not nixpkgs' cross LLVM-21
              # (version-skewed objects -> "malformed uleb128" when TH links).
              "--with-gcc=${pkgs.lib.getExe' wasiSdk "clang"}"
              "--with-ld=${pkgs.lib.getExe' wasiSdk "wasm-ld"}"
              "--with-ar=${pkgs.lib.getExe' wasiSdk "llvm-ar"}"
              "--disable-library-stripping"
              "--disable-executable-stripping"
              # text (via simdutf) needs wasi-sdk's libc++ (LLVM-19, std::__2::);
              # nixpkgs' cross cc puts LLVM-21 libcxx (std::__1::) on -L, so a bare
              # -lc++ picks the wrong ABI. Link wasi-sdk's by absolute path.
              "--ghc-option=-optl${wasiSdk}/share/wasi-sysroot/lib/wasm32-wasi/libc++.a"
              "--ghc-option=-optl${wasiSdk}/share/wasi-sysroot/lib/wasm32-wasi/libc++abi.a"
            ];
        });
  });
in {
  inherit packages; # the wasm32-wasi haskell package set (no per-package patches)
  inherit (cross.haskell) lib; # haskell.lib, for the consumer's overrideCabal
  inherit (wrappedGhc.passthru) binaryen; # for the consumer's wasm-opt
}
