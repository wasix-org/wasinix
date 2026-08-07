# The Flang frontend cross-built to run under WASIX and emit wasm32 objects.
# Full Fortran linking remains the responsibility of the native wasixflang
# driver because it also has to inject the profile-specific flang runtime.
{
  final,
  prev,
  helpers,
  toolchain,
  ...
}: let
  libllvm = final.llvm.passthru.wasix.libllvm;
  libclang = prev.llvmPackages.libclang.override {
    version = toolchain.llvm.llvm.version;
    release_version = toolchain.llvmVersion;
    monorepoSrc = toolchain.llvmMonorepoSrc;
    inherit libllvm;
    enableClangToolsExtra = false;
    extraPatches = [../clang/wasm-visibility.patch];
    devExtraCmakeFlags = ["-DUNIX=ON"];
  };
  mlir =
    helpers.libTweaks {
      patches = [./external-mlir-tblgen.patch];
    }
    (prev.llvmPackages.mlir.override {
      version = toolchain.llvm.llvm.version;
      release_version = toolchain.llvmVersion;
      monorepoSrc = toolchain.llvmMonorepoSrc;
      inherit libllvm;
      devExtraCmakeFlags = ["-DUNIX=ON"];
    });
  base = prev.llvmPackages.flang-unwrapped.override {
    version = toolchain.llvm.llvm.version;
    release_version = toolchain.llvmVersion;
    monorepoSrc = toolchain.llvmMonorepoSrc;
    inherit libllvm libclang mlir;
  };
in
  helpers.libTweaks {
    patches = [
      ./wasm32-target.patch
      ./wasm32-main.patch
    ];
    passthru.wasix = {
      shipped = true;
      updateNotes = [
        {message = "drop wasm32-target.patch once upstream Flang has a WebAssembly target ABI";}
        {message = "drop wasm32-main.patch once upstream Flang emits WASI's two-argument main entry";}
        {message = "drop external-mlir-tblgen.patch once standalone MLIR preserves a supplied native tablegen when cross compiling";}
        {message = "recheck standalone WASIX Flang linking when the profile-specific runtime can be selected inside a webc";}
      ];
    };
    passthru.wasmer = {
      name = "flang";
      entrypoint = "flang";
      commands = [
        {
          name = "flang";
          module = "flang";
          wasm = "flang.wasm";
          output = "flang.wasm";
          mainArgs = [
            "--target=wasm32-wasix"
            "--sysroot=/sysroot"
          ];
        }
      ];
      fs."/sysroot" = toolchain.variants.exnrefEh.sysroot;
    };

    cmakeFlags = ["-DUNIX=ON"];
    nativeBuildInputs = [final.disableWasmOptInConfigureHook];
    ninjaFlags = ["flang"];
    installPhase = _old: ''
      runHook preInstall
      mkdir -p "$out/bin"
      if [ -x bin/flang ]; then
        cp bin/flang "$out/bin/flang.wasm"
      else
        cp bin/flang-new "$out/bin/flang.wasm"
      fi
      runHook postInstall
    '';
    postInstall = _old: "";
  }
  base
