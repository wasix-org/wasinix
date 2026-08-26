# lld cross-built as a WASIX multicall executable. Link only the WebAssembly
# backend supplied by the same patched LLVM fork as the llvm utility webc.
{
  exposeWasixPackage,
  extendPackage,
  packageSet,
  packages,
}:
exposeWasixPackage (
  let
    wasixLlvm = packages.sameProfile.wasix-llvm.passthru;
    libllvm = packages.sameProfile.llvm.passthru.wasix.libllvm;
    base = packages.sameProfile.llvmPackages.lld.override {
      inherit (wasixLlvm) version;
      release_version = wasixLlvm.llvmVersion;
      inherit (wasixLlvm) monorepoSrc;
      inherit libllvm;
    };
  in
    extendPackage base {
      passthru.wasinix = {
        shipped = true;
        update.notes = [
          {message = "recheck the WASIX lld command set when the toolchain fork base version moves";}
        ];
      };
      passthru.wasmer = {
        name = "lld";
        entrypoint = "wasm-ld";
        commands =
          map (name: {
            inherit name;
            module = "lld";
            wasm = "lld.wasm";
            output = "${name}.wasm";
          }) [
            "wasm-ld"
            "ld.lld"
            "lld"
          ];
      };

      cmakeFlags = [
        "-DUNIX=ON"
        "-DLLD_BUILD_TOOLS=ON"
      ];
      nativeBuildInputs = [packageSet.disableWasmOptInConfigureHook];
      ninjaFlags = ["lld"];
      installPhase = _old: ''
        runHook preInstall
        mkdir -p "$out/bin" "$lib" "$dev"
        cp bin/lld "$out/bin/lld.wasm"
        runHook postInstall
      '';
    }
)
