# Clang cross-built to run under WASIX and target the bundled WASIX sysroot.
# lld is a webc dependency so the driver can perform both compile-only and link
# invocations without relying on a host installation.
{
  final,
  prev,
  helpers,
  toolchain,
  preferredProfilePackages,
  ...
}: let
  major = prev.lib.versions.major toolchain.llvmVersion;
  monorepoSrc = toolchain.llvmMonorepoSrc;
  base = prev.llvmPackages.clang-unwrapped.override {
    version = toolchain.llvm.llvm.version;
    release_version = toolchain.llvmVersion;
    inherit monorepoSrc;
    libllvm = final.llvm.passthru.wasix.libllvm;
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
  helpers.libTweaks {
    passthru.wasix = {
      shipped = true;
      updateNotes = [
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
      dependencies = [preferredProfilePackages.lld];
      fs = {
        "/sysroot" = toolchain.variants.exnrefEh.sysroot;
        "/lib/clang/${major}/include" = "${monorepoSrc}/clang/lib/Headers";
      };
    };

    cmakeFlags = [
      "-DUNIX=ON"
      "-DCLANG_DEFAULT_LINKER=wasm-ld"
      "-DCLANG_DEFAULT_CXX_STDLIB=libc++"
      "-DCLANG_DEFAULT_RTLIB=compiler-rt"
    ];
    patches = [./wasm-visibility.patch];
    nativeBuildInputs = [final.disableWasmOptInConfigureHook];
    ninjaFlags = ["clang"];
    installPhase = _old: ''
      runHook preInstall
      mkdir -p "$out/bin" "$lib" "$dev" "$python"
      cp bin/clang "$out/bin/clang.wasm"
      runHook postInstall
    '';
    # The nixpkgs hook splits ancillary host scripts that this focused build
    # deliberately does not produce.
    postInstall = _old: "";
  }
  base
