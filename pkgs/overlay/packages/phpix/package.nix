# phpix — the PHP runtime/server for wasix (wasmerio/phpix): a cargo-wasix Rust program that embeds
# our static php85 libphp. Ported from the old pkgs/programs/phpix (mk-phpix-wasix + phpixPhp85).
# Built on the build host via cargo-wasix (targeting wasm32-wasmer-wasi), linking php's libphp.a +
# its phpExtraLibDirs/phpExtraLinkLibs. exnrefEh-only — must match php's profile/EH mode.
{
  final,
  prev,
  toolchain,
  ...
}: let
  lib = prev.lib;
  php = final.php;
  # build-platform rustPlatform — only for cargoSetupHook + importCargoLock (vendoring the lock);
  # the actual compile goes through cargo-wasix.
  rustPlatform = final.buildPackages.rustPlatform;
in
  final.buildPackages.stdenvNoCC.mkDerivation {
    pname = "phpix";
    version = "0.1.12803";

    # phpix is a private repo, vendored as the vendor/phpix submodule. Build with
    # `nix build '.?submodules=1#…'` so the flake tree includes it; the rev is pinned by the
    # submodule gitlink (bump via `git submodule update --remote vendor/phpix`).
    src = ../../../../vendor/phpix;

    cargoDeps = rustPlatform.importCargoLock {
      lockFile = ./phpix.Cargo.lock;
      allowBuiltinFetchGit = true;
      # wasix-abi-rust bundles wasix-witx as a git submodule pinned to a rev that isn't on witx's
      # main branch, so importCargoLock's builtin fetchGit can't resolve it. Route this one dep
      # through fetchgit (submodule-aware + ref-agnostic) by pinning its hash here.
      outputHashes = {
        "wasix-0.13.1" = "sha256-HBCqkQivakAVUmnonThNj/D0HbRDtCummXQfvLpx1xY=";
      };
    };

    nativeBuildInputs = [
      rustPlatform.cargoSetupHook
      toolchain.cargoWasix
      toolchain.wasixcc
      toolchain.wasixLlvm
      # pkgsBuildBuild (fully native x86_64), NOT buildPackages — the latter is the build->host
      # cross set, whose `gcc` is the unbuildable x86_64->wasm cross compiler. These are host-side
      # build tooling: gcc links the x86_64 proc-macro/build-script artifacts, libclang runs bindgen.
      final.pkgsBuildBuild.gcc
      final.pkgsBuildBuild.llvmPackages.libclang
    ];

    prePatch = ''
      cp ${./phpix.Cargo.lock} Cargo.lock
      # report_memleaks: PHP 8.5 deprecates the INI route, but request shutdown still reads the flag
      # to reclaim per-request memory; patch the Zend global directly for long-running workers.
      patch -N -p1 --batch < ${./patches/report-memleaks.patch} || true
      # build.rs's extra-libs const omits several transitive deps of the bundled extensions
      # (libpgcommon/pgport, lcms2, openjpeg, libdeflate, zstd, brotli, webpmux/demux), leaving them
      # as undefined wasm imports — add them so the module instantiates.
      patch -p1 --batch < ${./patches/link-extra-libs.patch}
    '';

    buildPhase = ''
      runHook preBuild

      export HOME="$PWD/.home"
      export CARGO_HOME="$HOME/.cargo"
      export RUSTUP_HOME="$HOME/.rustup"
      mkdir -p "$HOME" "$CARGO_HOME" "$RUSTUP_HOME"

      SYSROOT_PATH="$(wasixccenv -sWASM_EXCEPTIONS=yes print-sysroot)"
      compat_lib_dir="$PWD/.php-link-compat"
      mkdir -p "$compat_lib_dir"
      # PHP is built with LTO; some archived bitcode objects carry linker options for libraries
      # provided by the sysroot/runtime surface rather than standalone Nix archives. Provide empty
      # compat archives so wasm-ld accepts those names while libc/other archives resolve the symbols.
      for lib in charset iconv icrt icutu; do
        wasixar crs "$compat_lib_dir/lib''${lib}.a"
      done
      export WASIX_PHP_HOME="${php}"
      export WASIX_PHP_EXTRA_LIB_DIR="$compat_lib_dir:${lib.concatStringsSep ":" php.phpExtraLibDirs}:$SYSROOT_PATH/lib/wasm32-wasi"
      export WASIX_PHP_EXTRA_LIBS="${lib.concatStringsSep ":" php.phpExtraLinkLibs}"
      export LIBCLANG_PATH="${final.pkgsBuildBuild.llvmPackages.libclang.lib}/lib"
      export CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER="${final.pkgsBuildBuild.gcc}/bin/gcc"

      cargo-wasix wasix build --release --frozen --offline

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p "$out/bin"
      cp target/wasm32-wasmer-wasi/release/phpix.wasm "$out/bin/phpix.wasm"
      runHook postInstall
    '';

    passthru.wasix.supportedProfiles = ["exnrefEh"];
    passthru.wasix.shipped = true;
    # The manifest entrypoint is what makes `wasmer run <pkg>` consult the
    # command's detected wasm features (tail calls!) when picking its engine;
    # without it the default engine rejects the module.
    passthru.wasmer.entrypoint = "phpix";

    meta = {
      description = "PHPix — PHP runtime/server for wasix, embedding static php85 libphp";
      homepage = "https://github.com/wasmerio/phpix";
      license = lib.licenses.mit;
      mainProgram = "phpix";
    };
  }
