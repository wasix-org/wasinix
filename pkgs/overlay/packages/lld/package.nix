# lld cross-built as a WASIX multicall executable. Link only the WebAssembly
# backend supplied by the same patched LLVM fork as the llvm utility webc.
{
  final,
  prev,
  helpers,
  toolchain,
  ...
}: let
  libllvm = final.llvm.passthru.wasix.libllvm;
  base = prev.llvmPackages.lld.override {
    version = toolchain.llvm.llvm.version;
    release_version = toolchain.llvmVersion;
    monorepoSrc = toolchain.llvmMonorepoSrc;
    inherit libllvm;
  };
in
  helpers.libTweaks {
    passthru.wasix = {
      shipped = true;
      updateNotes = [
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
    nativeBuildInputs = [final.disableWasmOptInConfigureHook];
    ninjaFlags = ["lld"];
    installPhase = _old: ''
      runHook preInstall
      mkdir -p "$out/bin" "$lib" "$dev"
      cp bin/lld "$out/bin/lld.wasm"
      runHook postInstall
    '';
  }
  base
