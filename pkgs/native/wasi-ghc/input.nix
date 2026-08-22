{
  pkgs,
  ghcWasm,
}: let
  wasiSdk = ghcWasm.wasi-sdk;
  baseGhc = ghcWasm.wasm32-wasi-ghc-9_12;
  version = "9.12.1";

  # The bindist's ranlib crashes after ar has already written the symbol table.
  # Its wrappers need the patched topdir because /proc/self/exe resolves their
  # symlinks, and the node linker must be copied so its relative paths stay in it.
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
  addCompilerInterface = package:
    package
    // {
      pname = "wasi-ghc";
      inherit version;
      targetPrefix = "wasm32-wasi-";
      haskellCompilerName = "ghc-${version}";
      hasHaddock = false;
      isHaLVM = false;
      isGhcjs = false;
      isMhs = false;
      # The wasm RTS TH interpreter loads splice dependencies as shared objects.
      enableShared = true;
      passthru =
        (package.passthru or {})
        // {
          inherit (ghcWasm) binaryen nodejs;
          inherit wasiSdk;
        };
      meta =
        (package.meta or (baseGhc.meta or {}))
        // {
          description = "GHC cross compiler targeting wasm32-wasi";
          mainProgram = "wasm32-wasi-ghc";
        };
      overrideAttrs = transform: addCompilerInterface (package.overrideAttrs transform);
    };
in
  addCompilerInterface patchedGhc
