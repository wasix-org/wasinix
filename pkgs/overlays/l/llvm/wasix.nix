# LLVM cross-built to run under WASIX. Reuse the exact fork source that builds
# the host toolchain; its WebAssembly backend carries the WASIX TLS and linker
# changes, while nixpkgs supplies the native tablegen cross-build machinery.
{
  exposeWasixPackage,
  extendPackage,
  package,
  packageSet,
  packages,
}:
exposeWasixPackage (
  let
    wasixLlvm = packages.sameProfile.wasix-llvm.passthru;
    base = package.override {
      inherit (wasixLlvm) version;
      release_version = wasixLlvm.llvmVersion;
      inherit (wasixLlvm) monorepoSrc;
      enablePFM = false;
      enablePolly = false;
      enableTerminfo = false;
    };
    common = extendPackage base {
      patches = [
        ./support-wasix.patch
        ./unix-optional-dlfcn.patch
        ./wasi-endian.patch
      ];

      # LLVM's support library probes optional host integrations by default.
      # Keep WASIX builds self-contained and restrict code generation to the
      # backend used by every frontend and utility package in this directory.
      cmakeFlags = [
        # CMake does not classify WasiP1 as Unix. LLVM's platform selection and
        # the older WASIX build-scripts recipe both require this explicitly.
        "-DUNIX=ON"
        "-DLLVM_TARGETS_TO_BUILD=WebAssembly"
        "-DLLVM_ENABLE_THREADS=ON"
        "-DHAVE_SIGALTSTACK=OFF"
        "-DLLVM_ENABLE_FFI=OFF"
        "-DLLVM_ENABLE_TERMINFO=OFF"
        "-DLLVM_ENABLE_ZLIB=OFF"
        "-DLLVM_ENABLE_ZSTD=OFF"
        "-DLLVM_ENABLE_LIBEDIT=OFF"
        "-DLLVM_ENABLE_LIBXML2=OFF"
        "-DLLVM_ENABLE_CURL=OFF"
        "-DLLVM_INCLUDE_BENCHMARKS=OFF"
        "-DLLVM_INCLUDE_EXAMPLES=OFF"
        "-DLLVM_INCLUDE_TESTS=OFF"
      ];
      nativeBuildInputs = [packageSet.disableWasmOptInConfigureHook];
    };
    libllvm = extendPackage common {
      # Frontends consume LLVM's libraries and CMake package only. Building every
      # unrelated target utility reaches lli, whose child-executor mode assumes
      # fork(2), and needlessly makes each frontend wait for the whole CLI suite.
      cmakeFlags = ["-DLLVM_BUILD_TOOLS=OFF"];
      # nixpkgs expects llvm-config in LLVMExports, but LLVM_BUILD_TOOLS=OFF
      # installs it only as a target helper and creates no native copy. Preserve
      # the useful output split without requiring those absent artifacts.
      postInstall = _old: ''
        mkdir -p "$python/share"
        if [ -d "$out/share/opt-viewer" ]; then
          mv "$out/share/opt-viewer" "$python/share/opt-viewer"
        fi
        moveToOutput "bin/llvm-config*" "$dev"
        substituteInPlace "$dev/lib/cmake/llvm/LLVMConfig.cmake" \
          --replace-fail 'set(LLVM_BINARY_DIR "''${LLVM_INSTALL_PREFIX}")' 'set(LLVM_BINARY_DIR "'"$lib"'")'
      '';
    };
    buildTools = [
      "llc"
      "opt"
      "llvm-as"
      "llvm-bcanalyzer"
      "llvm-cxxfilt"
      "llvm-dis"
      "llvm-dwarfdump"
      "llvm-link"
      "llvm-nm"
      "llvm-objcopy"
      "llvm-objdump"
      "llvm-readobj"
      "llvm-size"
      "llvm-strings"
    ];
    toolAliases = {
      llvm-readelf = "llvm-readobj";
      llvm-strip = "llvm-objcopy";
    };
    shippedTools = buildTools ++ builtins.attrNames toolAliases;
  in
    extendPackage common {
      passthru = {
        wasix = {
          # Frontends link this complete, consistently patched LLVM build. The
          # llvm webc itself installs only command-line utilities from the same
          # base.
          inherit libllvm;
        };
        wasinix = {
          shipped = true;
          update.notes = [
            {
              message = "recheck the WASIX LLVM tool selection and cross-build flags when the toolchain fork base version moves";
            }
            {
              message = "drop support-wasix.patch once upstream LLVM supports WASIX in its Unix support layer";
            }
            {message = "drop unix-optional-dlfcn.patch once upstream LLVM guards dlfcn.h with HAVE_DLOPEN";}
            {message = "drop wasi-endian.patch once upstream LLVM recognizes WASI's endian.h";}
          ];
        };
        wasmer = {
          name = "llvm";
          commands = map (name: {inherit name;}) shippedTools;
        };
      };

      ninjaFlags = shippedTools;
      installTargets = map (tool: "install-${tool}") shippedTools;

      # The nixpkgs post-install phase expects the complete development install.
      # This package intentionally installs only the WASIX command set.
      postInstall = _old: ''
        mkdir -p "$lib" "$dev" "$python"
        for tool in ${packages.sameProfile.lib.escapeShellArgs buildTools}; do
          test -f "$out/bin/$tool"
          mv "$out/bin/$tool" "$out/bin/$tool.wasm"
        done
        ${packages.sameProfile.lib.concatStringsSep "\n" (
          packages.sameProfile.lib.mapAttrsToList (alias: target: ''
            test -L "$out/bin/${alias}"
            rm "$out/bin/${alias}"
            ln -s "${target}.wasm" "$out/bin/${alias}.wasm"
          '')
          toolAliases
        )}
      '';
    }
)
