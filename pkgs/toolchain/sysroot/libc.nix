# One ABI variant of the wasix libc, built from source. It needs *a* clang, not the
# fork LLVM, since the Makefile supplies the ABI flags itself.
{
  lib,
  stdenv,
  fetchFromGitHub,
  rustPlatform,
  nix-update-script,
  writeText,
  llvmPackages_21,
  gnumake,
  rsync,
  python3,
  cargo,
  rustc,
  coreutils,
  writableTmpDirAsHomeHook,
  eh ? false,
  pic ? false,
  exnref ? false,
}: let
  version = "2026-07-30.1";
  src = fetchFromGitHub {
    owner = "wasix-org";
    repo = "wasix-libc";
    tag = "v${version}";
    hash = "sha256-UGBHCYuUlNE6fAAUJnPxIgfJ7ujiUKGUrWU+BFKQfsQ=";
  };

  # PIC is orthogonal to EH; `exnref` only matters when `eh`.
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

  # witx specs for the header generators: submodule pins absent from archive
  # downloads, synced by scripts/update.py. A stale pin fails the build with
  # undeclared __wasi_* functions.
  wasiWitx = fetchFromGitHub {
    owner = "WebAssembly";
    repo = "WASI";
    rev = "bac366c8aeb69cacfea6c4c04a503191bf1cede1";
    hash = "sha256-Nj15jrOuBN1VTk8xwSEIJo2a7rr6fLeyYjy0Y/oU178=";
  };
  wasixWitx = fetchFromGitHub {
    owner = "wasix-org";
    repo = "wasix-witx";
    rev = "0dfbd35a0f30f3fe7fd3b3ab5a50dc4191d5caed";
    hash = "sha256-UNdASQKquBTFF9FhJ5NLcy5lxSUTIvaDUO5PG5BWMUg=";
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

    passthru.updateScript = {
      name = "wasix-libc"; # the attr tail is `libc`
      # Wraps nix-update (passed through as argv) to re-derive the witx pins at the new tag.
      command = ["pkgs/toolchain/sysroot/update.py"] ++ nix-update-script {extraArgs = ["--flake"];};
    };

    nativeBuildInputs = [
      # Unwrapped: wasix-libc drives the target itself.
      llvmPackages_21.clang-unwrapped
      llvmPackages_21.llvm
      llvmPackages_21.lld
      gnumake
      rsync
      python3
      cargo
      rustc
      coreutils
      writableTmpDirAsHomeHook
    ];

    # select()/pselect() bail with ENOSYS when exceptfds is non-empty, spinning
    # defensive callers. tzname, inet-addr and sched unhide declarations sitting
    # behind __wasilibc_unmodified_upstream while the symbols themselves link, so a
    # consumer naming one gets "undeclared identifier"; inet-addr also adds musl's
    # inet_addr.c, missing from the Makefile source list. fcntl-locking exposes the
    # record-lock API but returns ENOSYS until Wasmer provides shared lock state.
    # xsi-signal is the same unhiding for the XSI signal calls (siginterrupt and
    # friends), which are built on sigaction.
    patches = [
      ./libc-select-exceptfds.patch
      ./wasix-libc-tzname.patch
      ./wasix-libc-inet-addr.patch
      ./wasix-libc-sched.patch
      ./wasix-libc-fcntl-locking.patch
      ./wasix-libc-xsi-signal.patch
    ];

    passthru.wasix.updateNotes = [
      {message = "check whether libc-select-exceptfds.patch landed upstream (WASIX-TODO.md)";}
    ];

    dontConfigure = true;

    env = {
      CARGO_NET_OFFLINE = "true";
      TARGET_ARCH = "wasm32";
      TARGET_OS = "wasix";
    };

    # Stubs for declared-but-unbuilt POSIX functions (mlock, madvise, sched_*); the
    # Makefile globs libc-bottom-half/sources/*.c. See WASIX-TODO.md.
    postPatch = ''
      cp ${./wasix-libc-stubs.c} libc-bottom-half/sources/wasix-stubs.c

      rm -rf tools/wasi-headers/WASI tools/wasix-headers/WASI
      cp -r --no-preserve=mode,ownership ${wasiWitx}  tools/wasi-headers/WASI
      cp -r --no-preserve=mode,ownership ${wasixWitx} tools/wasix-headers/WASI
      cp tools/wasix-headers/Cargo.lock tools/wasi-headers/Cargo.lock
      mkdir -p .cargo
      cp ${cargoConfig} .cargo/config.toml
    '';

    # Regenerate the wasi/wasix api headers, as build32-general.sh does.
    preBuild = ''
      cargo run --manifest-path tools/wasix-headers/Cargo.toml generate-libc
      cp -f libc-bottom-half/headers/public/wasi/api.h libc-bottom-half/headers/public/wasi/api_wasix.h
      sed -i 's|__wasi__|__wasix__|g; s|__wasi_api_h|__wasix_api_h|g' \
        libc-bottom-half/headers/public/wasi/api_wasix.h
      cp -f libc-bottom-half/sources/__wasilibc_real.c libc-bottom-half/sources/__wasixlibc_real.c
      cargo run --manifest-path tools/wasi-headers/Cargo.toml generate-libc
      cp -f libc-bottom-half/headers/public/wasi/api.h libc-bottom-half/headers/public/wasi/api_wasi.h
      printf '#include "api_wasi.h"\n#include "api_wasix.h"\n#include "api_poly.h"\n' \
        > libc-bottom-half/headers/public/wasi/api.h
    '';

    # The toolchain goes on the make COMMAND LINE, not the environment: the stdenv's
    # cc-wrapper hook exports CC=gcc after env attrs, and command-line variables are
    # the one thing that overrides it.
    makefile = makeFile;
    makeFlags =
      [
        "CHECK_SYMBOLS=no"
        "CC=clang"
        "CXX=clang++"
        "NM=llvm-nm"
        "AR=llvm-ar"
        "RANLIB=llvm-ranlib"
      ]
      ++ makeVariantArgs;
    enableParallelBuilding = true;

    # Generate libc.imports, the host-imported symbols wasixcc feeds to wasm-ld as
    # --allow-undefined-file. CHECK_SYMBOLS=no skips the Makefile target producing it.
    postBuild = ''
      rm -f sysroot/lib/wasm32-wasi/libc-printscan-long-double.a

      lib_dir=sysroot/lib/wasm32-wasi
      llvm-nm --undefined-only "$lib_dir"/libc.a "$lib_dir"/libc-*.a "$lib_dir"/*.o 2>/dev/null \
        | grep ' U ' | sed 's/.* U //' | LC_ALL=C sort | uniq \
        | grep '^_*imported_wasix_' > "$lib_dir/libc.imports" || true
    '';

    # Sysroot-shaped output, as wasix-libc's Makefile installs it under sysroot/.
    installPhase = ''
      runHook preInstall
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
