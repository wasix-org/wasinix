# nixpkgs haskellPackages driving ghc-wasm-meta's prebuilt wasm32-wasi GHC.
# Exposes `packages`, a haskell package set carrying the global wasm build config
# (no per-package patches; those belong to the consumer). TemplateHaskell works
# because wasm32-wasi runs the splice interpreter under node; the from-source
# wasix GHC can't (node can't host a wasix interpreter), which is why it's separate.
{
  pkgs,
  ghcWasm,
}: let
  # allowUnsupportedSystem: nixpkgs marks most of haskellPackages unsupported on wasm.
  cross = import pkgs.path {
    system = "x86_64-linux";
    config.allowUnsupportedSystem = true;
    crossSystem = {
      config = "wasm32-unknown-wasi";
      useLLVM = true;
    };
  };

  wasiSdk = ghcWasm.wasi-sdk;
  baseGhc = ghcWasm.wasm32-wasi-ghc-9_12;
  # Patch the cp -as'd bindist tree (notes kept out of the string below so edits
  # don't rebuild the closure):
  # - chmod only the dirs we touch (recursive over the 3.2GB tree is slow).
  # - Neuter the redundant ranlib: settings declare `ar flags = qcls` (writes the
  #   symtab) AND a `ranlib command`; the extra re-index crashes ("malformed
  #   uleb128") in the sandbox.
  # - The relocatable ghc locates its topdir via /proc/self/exe, which resolves
  #   into the unpatched bindist, so add -B<patched lib> to the wrapper exec
  #   lines. Only the two ghc entry points are wrapper scripts; their node
  #   PATH/NODE_PATH exports must survive (the TH dyld needs that node and its
  #   npm deps), so only the exec line is edited.
  # - dyld.mjs (the node TH linker) must be a real file, not a symlink: node
  #   resolves it back into the bindist, so relative loads escape the patched tree
  #   and some TH splices die with "remoteCall: end of file".
  # The versioned wrapper name is globbed so a point bump needs no edit.
  patchedGhc = pkgs.runCommand "wasm32-wasi-ghc-9.12-noranlib" {} ''
    mkdir -p "$out"
    cp -as ${baseGhc}/. "$out/"
    chmod u+w "$out" "$out/bin" "$out/lib"
    rm "$out/lib/settings"
    substitute ${baseGhc}/lib/settings "$out/lib/settings" \
      --replace-fail '"${pkgs.lib.getExe' wasiSdk "llvm-ranlib"}"' '"${pkgs.lib.getExe' pkgs.buildPackages.coreutils "true"}"'
    for name in $(cd "$out/bin" && echo wasm32-wasi-ghc wasm32-wasi-ghc-9.*); do
      rm "$out/bin/$name"
      substitute ${baseGhc}/bin/"$name" "$out/bin/$name" \
        --replace-fail '"$@"' "-B$out/lib \"\$@\""
      chmod +x "$out/bin/$name"
    done
    rm "$out/lib/dyld.mjs"
    cp ${baseGhc}/lib/dyld.mjs "$out/lib/dyld.mjs"
    chmod +x "$out/lib/dyld.mjs"
  '';

  wrappedGhc =
    patchedGhc
    // {
      version = "9.12.1";
      targetPrefix = "wasm32-wasi-";
      haskellCompilerName = "ghc-9.12.1";
      hasHaddock = false;
      isHaLVM = false;
      isGhcjs = false;
      isMhs = false;
      # The wasm RTS TH interpreter loads splice deps as .so, so advertise
      # shared-lib support to let generic-builder pass --enable-shared.
      enableShared = true;
    };

  # The wasm build config applied to every package, via the set's mkDerivation.
  # Per-package fixes are the consumer's job, not the toolchain's.
  packages = (cross.haskell.packages.ghc9123.override {ghc = wrappedGhc;}).extend (final: prev: {
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
          buildTools = (args.buildTools or []) ++ [ghcWasm.nodejs];
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
  inherit (ghcWasm) binaryen; # for the consumer's wasm-opt
}
