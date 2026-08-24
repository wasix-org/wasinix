# Clang cross-built to run under WASIX and target the bundled WASIX sysroot.
# lld is a webc dependency so the driver can perform both compile-only and link
# invocations without relying on a host installation.
{
  exposePackage,
  extendPackage,
  packages,
  wasmRename,
}:
exposePackage (
  let
    wasixLlvm = packages.sameProfile.wasix-llvm.passthru;
    major = packages.sameProfile.lib.versions.major wasixLlvm.llvmVersion;
    inherit (wasixLlvm) monorepoSrc;
    base = packages.sameProfile.llvmPackages.clang-unwrapped.override {
      inherit (wasixLlvm) version;
      release_version = wasixLlvm.llvmVersion;
      inherit monorepoSrc;
      libllvm = packages.sameProfile.llvm.passthru.wasix.libllvm;
      enableClangToolsExtra = false;
    };
    command = name: {
      inherit name;
      module = "clang";
      wasm = "clang.wasm";
      output = "${name}.wasm";
      mainArgs = [
        "--target=wasm32-wasix"
        "--sysroot=/sysroot"
        "-resource-dir=/lib/clang/${major}"
      ];
    };
  in
    wasmRename {wasmName = "clang";} (extendPackage base {
      passthru.wasinix = {
        shipped = true;
        update.notes = [
          {message = "recheck the WASIX Clang resource headers and default driver arguments when the toolchain fork base version moves";}
          {message = "drop wasm-visibility.patch once upstream Clang recognizes the standard __wasm__ target macro";}
        ];
      };
      passthru.wasmer = {
        name = "clang";
        entrypoint = "clang";
        commands = map command [
          "clang"
          "clang++"
        ];
        dependencies = [packages.preferred.lld];
        fs = {
          "/sysroot" = packages.native."wasix-sysroot".profiles.exnrefEh.sysroot;
          "/lib/clang/${major}/include" = "${monorepoSrc}/clang/lib/Headers";
        };
      };

      cmakeFlags = [
        "-DUNIX=ON"
        "-DCLANG_DEFAULT_LINKER=wasm-ld"
        "-DCLANG_DEFAULT_CXX_STDLIB=libc++"
        "-DCLANG_DEFAULT_RTLIB=compiler-rt"
      ];
      patches = [
        ./wasm-visibility.patch
        ./no-fork-remote-jit.patch
        ./dlfcn-optional.patch
      ];
      nativeBuildInputs = [packages.sameProfile.disableWasmOptInConfigureHook];
    })
)
