# The Flang frontend cross-built to run under WASIX and emit wasm32 objects.
# Full Fortran linking remains the responsibility of the native wasixflang
# driver because it also has to inject the profile-specific flang runtime.
{
  final,
  prev,
  helpers,
  toolchain,
  nixpkgs,
  ...
}: let
  libllvm = final.llvm.passthru.wasix.libllvm;
  libclang = final.clang;
  # MLIR runs mlir-linalg-ods-yaml-gen during its own build, so a cross build
  # needs a host copy; without one the wasm binary is invoked and the build stops
  # at "cannot execute binary file". Upstream's setup_host_tool accepts one, and
  # the tblgen helper already builds host LLVM tools with MLIR enabled.
  nativeOdsYamlGen = final.buildPackages.llvmPackages.tblgen.overrideAttrs (old: {
    targets = old.targets ++ ["mlir-linalg-ods-yaml-gen"];
    ninjaFlags = old.ninjaFlags ++ ["mlir-linalg-ods-yaml-gen"];
  });
  mlir =
    helpers.libTweaks {
      patches = [./external-mlir-tblgen.patch];
      # get_host_tool_path caches MLIR_LINALG_ODS_YAML_GEN and derives the _EXE
      # variable from it, so the setting name is what a caller supplies.
      # LLVM_BUILD_UTILS keeps the target in the build: supplying a host tool marks
      # it EXCLUDE_FROM_ALL, yet add_mlir_tool still installs it, so the install
      # phase looks for a binary nothing built. The wasm copy is never executed.
      cmakeFlags = [
        "-DMLIR_LINALG_ODS_YAML_GEN=${nativeOdsYamlGen}/bin/mlir-linalg-ods-yaml-gen"
        "-DLLVM_BUILD_UTILS=ON"
      ];
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
    # nativeBuildInputs wants a build-host compiler, but this set's buildPackages
    # still resolves clang to the cross wrapper, so cmake probes with a driver
    # whose resource root holds no builtins archive for this target.
    clang = nixpkgs.legacyPackages.${final.stdenv.buildPlatform.system}.clang;
    inherit libllvm libclang mlir;
  };
in
  helpers.libTweaks {
    patches = [
      ./wasm32-target.patch
      ./wasm32-main.patch
      ./wasm32-pointer-width.patch
      ./wasm32-fenv.patch
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
    # flang stores subscripts as 64-bit and narrows them into size_t, which the
    # compiler rejects where size_t is 32 bits. A wasm32 address space cannot
    # hold an object whose subscript needs the discarded bits.
    env.NIX_CFLAGS_COMPILE = "-Wno-error=c++11-narrowing";
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
