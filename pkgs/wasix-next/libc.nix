# Build the wasix libc FROM SOURCE, one of the 5 ABI variants (see the matrix in
# default.nix). The variant is selected by the {eh, pic, exnref} booleans, which
# mirror build32-general.sh:wasix_libc (Makefile vs Makefile-eh, PIC=, EXNREF_EH=).
#
# The libc (musl-based) is independent of the LLVM *sources* — it only needs *a*
# clang to compile — so it builds with nixpkgs' llvmPackages_21 (fast, decoupled
# from the from-source LLVM build), with the Makefile supplying the ABI flags.
#
# Output is sysroot-shaped (lib/wasm32-wasi/ + include/), the same layout the
# compiler-rt/libcxx builds consume via --sysroot and the final sysroot merges.
{
  lib,
  stdenv,
  fetchFromGitHub,
  rustPlatform,
  writeText,
  llvmPackages_21,
  gnumake,
  rsync,
  python3,
  cargo,
  rustc,
  coreutils,
  # wasix-libc checkout (centralized pin in default.nix) + its version label.
  src,
  version,
  # ABI variant selectors (mirror wasix-libc's build32-general.sh).
  eh ? false,
  pic ? false,
  exnref ? false,
}: let
  # build32-general.sh:wasix_libc — EH picks Makefile-eh (+ EXNREF_EH), else the
  # base Makefile; PIC is orthogonal. `exnref` only matters when `eh`.
  variant =
    if !eh
    then "off"
    else "${lib.optionalString exnref "exnref-"}eh${lib.optionalString pic "-pic"}";
  makeFile =
    if eh
    then "Makefile-eh"
    else "Makefile";
  makeVariantArgs =
    [
      "PIC=${
        if pic
        then "yes"
        else "no"
      }"
    ]
    ++ lib.optionals eh [
      "EXNREF_EH=${
        if exnref
        then "yes"
        else "no"
      }"
    ];

  # witx specs for the header generators (cargo run generate-libc).
  wasiWitx = fetchFromGitHub {
    owner = "WebAssembly";
    repo = "WASI";
    rev = "bac366c8aeb69cacfea6c4c04a503191bf1cede1";
    hash = "sha256-Nj15jrOuBN1VTk8xwSEIJo2a7rr6fLeyYjy0Y/oU178=";
  };
  wasixWitx = fetchFromGitHub {
    owner = "wasix-org";
    repo = "wasix-witx";
    rev = "7295cec42d709e965c7fe9e57faeff23931c9b93";
    hash = "sha256-6sWezkhtrjIlZ9iWujFsiaIqlSVgkzKhfrt7adBELLI=";
  };

  cargoVendor = rustPlatform.importCargoLock {
    lockFile = ./libc-headers.Cargo.lock;
  };
  cargoConfig = writeText "wasix-libc-cargo-config.toml" ''
    [source.crates-io]
    replace-with = "vendored-sources"
    [source.vendored-sources]
    directory = "${cargoVendor}"
  '';
in
  stdenv.mkDerivation {
    pname = "wasix-libc-${variant}";
    inherit version src;

    nativeBuildInputs = [
      # raw (unwrapped) clang + llvm tools: wasix-libc drives the target itself.
      llvmPackages_21.clang-unwrapped
      llvmPackages_21.llvm
      llvmPackages_21.lld
      gnumake
      rsync
      python3
      cargo
      rustc
      coreutils
    ];

    CARGO_NET_OFFLINE = "true";
    dontConfigure = true;

    postPatch = ''
      rm -rf tools/wasi-headers/WASI tools/wasix-headers/WASI
      cp -r --no-preserve=mode,ownership ${wasiWitx}  tools/wasi-headers/WASI
      cp -r --no-preserve=mode,ownership ${wasixWitx} tools/wasix-headers/WASI
      cp tools/wasix-headers/Cargo.lock tools/wasi-headers/Cargo.lock
      mkdir -p .cargo
      cp ${cargoConfig} .cargo/config.toml
    '';

    buildPhase = ''
      runHook preBuild

      export HOME="$TMPDIR"
      export TARGET_ARCH=wasm32
      export TARGET_OS=wasix
      export CC=clang
      export CXX=clang++
      export NM=llvm-nm
      export AR=llvm-ar
      export RANLIB=llvm-ranlib

      # Regenerate the wasi/wasix api headers (build32-general.sh:prepare_wasix_libc).
      cargo run --manifest-path tools/wasix-headers/Cargo.toml generate-libc
      cp -f libc-bottom-half/headers/public/wasi/api.h libc-bottom-half/headers/public/wasi/api_wasix.h
      sed -i 's|__wasi__|__wasix__|g; s|__wasi_api_h|__wasix_api_h|g' \
        libc-bottom-half/headers/public/wasi/api_wasix.h
      cp -f libc-bottom-half/sources/__wasilibc_real.c libc-bottom-half/sources/__wasixlibc_real.c
      cargo run --manifest-path tools/wasi-headers/Cargo.toml generate-libc
      cp -f libc-bottom-half/headers/public/wasi/api.h libc-bottom-half/headers/public/wasi/api_wasi.h
      printf '#include "api_wasi.h"\n#include "api_wasix.h"\n#include "api_poly.h"\n' \
        > libc-bottom-half/headers/public/wasi/api.h

      # Build the libc only (the ${variant} variant; runtimes come from nixpkgs cross).
      make CHECK_SYMBOLS=no -j"''${NIX_BUILD_CORES:-4}" -f ${makeFile} ${lib.escapeShellArgs makeVariantArgs}
      rm -f sysroot/lib/wasm32-wasi/libc-printscan-long-double.a

      # Generate libc.imports — the list of host-imported (undefined) wasix symbols
      # wasixcc feeds to wasm-ld as --allow-undefined-file. The Makefile's
      # check-symbols target produces it, but we skip that (CHECK_SYMBOLS=no) to
      # avoid its brittle sanity checks, so reproduce just the imports extraction.
      lib_dir=sysroot/lib/wasm32-wasi
      llvm-nm --undefined-only "$lib_dir"/libc.a "$lib_dir"/libc-*.a "$lib_dir"/*.o 2>/dev/null \
        | grep ' U ' | sed 's/.* U //' | LC_ALL=C sort | uniq \
        | grep '^_*imported_wasix_' > "$lib_dir/libc.imports" || true

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      # Sysroot-shaped output: lib/wasm32-wasi/ + include/ (+ share/), exactly as
      # wasix-libc's Makefile installs it under sysroot/.
      mkdir -p "$out"
      cp -r sysroot/lib "$out/lib"
      cp -r sysroot/include "$out/include"
      [ -d sysroot/share ] && cp -r sysroot/share "$out/share" || true
      runHook postInstall
    '';

    meta = with lib; {
      description = "WASIX libc (${variant} variant), built from source";
      homepage = "https://github.com/wasix-org/wasix-libc";
      license = with licenses; [asl20 mit];
      platforms = platforms.unix;
    };
  }
