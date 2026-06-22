{
  lib,
  stdenvNoCC,
  rustPlatform,
  cargoWasix,
  gcc,
  llvmPackages,
  toolchain,
}: {
  pname,
  version,
  src,
  cargoLock,
  phpPackage,
  meta ? {},
}:
stdenvNoCC.mkDerivation {
  inherit pname version src;

  cargoDeps = rustPlatform.importCargoLock {
    lockFile = cargoLock;
    allowBuiltinFetchGit = true;
  };

  nativeBuildInputs = [
    rustPlatform.cargoSetupHook
    cargoWasix
    toolchain.wasixcc
    toolchain.wasixLlvm
    gcc
    llvmPackages.libclang
  ];

  prePatch = ''
    cp ${cargoLock} Cargo.lock
  '';

  buildPhase = ''
    runHook preBuild

    export HOME="$PWD/.home"
    export CARGO_HOME="$HOME/.cargo"
    export RUSTUP_HOME="$HOME/.rustup"
    mkdir -p "$HOME" "$CARGO_HOME" "$RUSTUP_HOME"

    SYSROOT_PATH="$(wasixccenv -sWASM_EXCEPTIONS=yes print-sysroot)"
    export WASIX_PHP_HOME="${phpPackage}"
    export WASIX_PHP_EXTRA_LIB_DIR="${lib.concatStringsSep ":" phpPackage.phpExtraLibDirs}:$SYSROOT_PATH/lib/wasm32-wasi"
    export WASIX_PHP_EXTRA_LIBS="${lib.concatStringsSep ":" phpPackage.phpExtraLinkLibs}"
    export PATH="${toolchain.wasixLlvm}/bin:$SYSROOT_PATH/../../llvm/bin:$PATH"

    export LIBCLANG_PATH="${llvmPackages.libclang.lib}/lib"
    export CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER="${gcc}/bin/gcc"
    cargo-wasix wasix build --release --frozen --offline

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/bin"
    cp target/wasm32-wasmer-wasi/release/phpix.wasm "$out/bin/phpix.wasm"
    runHook postInstall
  '';

  meta =
    {
      description = "PHPix server for WASIX";
      homepage = "https://github.com/wasmerio/phpix";
      license = lib.licenses.mit;
      platforms = lib.platforms.linux;
    }
    // meta;
}
