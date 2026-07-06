# The WASIX Rust toolchain (wasix-org/rust), built from source: `x.py build
# --stage 2` for the host plus the wasix std targets, mirroring upstream's
# build-wasix.sh + config.toml.wasix-template:
#   - LLVM is built in-tree (download-ci-llvm = false) after applying
#     wasix-llvm.patch, which carries the fork's WebAssembly lowering; a stock
#     nixpkgs LLVM can't substitute.
#   - the two std targets use the EH and EH+PIC libc sysroots (wasi-root), like
#     SYSROOT_EH / SYSROOT_EHPIC in build-wasix.sh.
#   - stage0 is the upstream rustc/cargo pinned in src/stage0 (1.89.0); the fork
#     only bootstraps from its immediate predecessor, so nixpkgs' rustc can't stand in.
# Output is the linked stage2 tree (bin/ + lib/rustlib/), the release-tarball
# layout cargo-wasix.nix expects.
{
  lib,
  stdenv,
  fetchFromGitHub,
  fetchurl,
  runCommand,
  linkFarm,
  formats,
  rustPlatform,
  nix-update-script,
  autoPatchelfHook,
  # x.py/cargo need a writable HOME.
  writableTmpDirAsHomeHook,
  python3,
  cmake,
  ninja,
  pkg-config,
  curl,
  openssl,
  zlib,
  libffi,
  xz,
  which,
  file,
  # From-source wasix LLVM (clang/lld) + the EH and EH+PIC libc sysroots.
  wasixLlvm,
  wasixSysrootEh,
  wasixSysrootEhpic,
  # Also build std for wasm32-wasmer-wasi-dl (the dynamic-linking / PIC target),
  # needed for PIC `.so` Rust artifacts (e.g. pyo3 python extensions).
  withDynamicLinking ? true,
}: let
  inherit (lib) optionals optionalString;
  version = "2026-07-03.1+rust-1.90";

  hostTriple = "x86_64-unknown-linux-gnu";

  # Full git checkout, including the src/llvm-project submodule we build in-tree.
  src = fetchFromGitHub {
    owner = "wasix-org";
    repo = "rust";
    tag = "v${version}";
    fetchSubmodules = true;
    hash = "sha256-am5SBlIW/Ff1EVvfo0KMBYPu3X7Ke0lQSqUEW+VELs0=";
  };

  # stage0 bootstrap compiler: the upstream release pinned in src/stage0, which
  # x.py would otherwise download itself.
  bootstrap = stdenv.mkDerivation {
    pname = "rust-bootstrap";
    version = "1.89.0";
    src = fetchurl {
      url = "https://static.rust-lang.org/dist/2025-08-07/rust-1.89.0-${hostTriple}.tar.xz";
      hash = "sha256-xPJ5axDuiGAB8HmbxAyuo4dGQDozw3nXeHjE9Gg/m1E=";
    };
    nativeBuildInputs = [autoPatchelfHook];
    buildInputs = [stdenv.cc.cc.lib zlib];
    installPhase = ''
      runHook preInstall
      patchShebangs install.sh
      ./install.sh \
        --prefix="$out" \
        --disable-ldconfig \
        --components=rustc,cargo,rust-std-${hostTriple}
      runHook postInstall
    '';
  };

  # Offline cargo registry for every workspace x.py compiles, each with its own
  # lockfile. vendor.nix vendors each and produces one source-replacement config;
  # crates-io and the cc-rs/libc git forks are vendored separately (vendor.nix
  # explains why the split is required).
  vendor = import ./vendor.nix {inherit lib rustPlatform linkFarm formats;} (
    map (p: "${src}/${p}") [
      "Cargo.lock"
      "library/Cargo.lock"
      "src/tools/cargo/Cargo.lock"
      "src/bootstrap/Cargo.lock"
    ]
  );

  # rust bootstrap's cc_detect.rs looks for a `-wasi` target's C compiler at
  # $WASI_SDK_PATH/bin/<target>-clang[++]; synthesize that layout from the wasix
  # clang + matching sysroot (eh for the base target, ehpic + -fPIC for -dl).
  wasiSdk = let
    mkClang = triple: sysroot: extra: ''
      for lang in clang clang++; do
        printf '#!%s\nexec "%s/bin/%s" --target=wasm32-wasi --sysroot="%s" ${extra} "$@"\n' \
          "${stdenv.shell}" "${wasixLlvm}" "$lang" "${sysroot}" > "$out/bin/${triple}-$lang"
        chmod +x "$out/bin/${triple}-$lang"
      done
    '';
  in
    runCommand "wasix-wasi-sdk" {} ''
      mkdir -p "$out/bin"
      ${mkClang "wasm32-wasmer-wasi" wasixSysrootEh ""}
      ${mkClang "wasm32-wasmer-wasi-dl" wasixSysrootEhpic "-fPIC"}
    '';
in
  stdenv.mkDerivation {
    pname = "wasix-rust-toolchain";
    inherit version src;

    nativeBuildInputs = [
      python3
      cmake
      ninja
      pkg-config
      which
      file
      # The built rustc/cargo need rpaths to zlib/libstdc++ (x.py doesn't embed
      # store rpaths).
      autoPatchelfHook
      writableTmpDirAsHomeHook
    ];

    buildInputs = [
      curl
      openssl
      zlib
      libffi
      xz
      stdenv.cc.cc.lib
    ];

    # x.py shells out to cmake itself; the nixpkgs cmake hook would inject flags it
    # doesn't expect.
    dontUseCmakeConfigure = true;
    enableParallelBuilding = true;
    requiredSystemFeatures = ["big-parallel"];

    env = {
      # Rust bootstrap special-cases CI environments; force it off.
      GITHUB_ACTIONS = "false";
      # Offline mode, not build.vendor: vendor forces cargo --frozen, which trips
      # over the fork's slightly stale lockfiles; offline still bars the network
      # but lets cargo refresh a lock in place.
      CARGO_NET_OFFLINE = "true";
      # The wasix C toolchain for the std targets' C compiler detection (cc_detect.rs).
      WASI_SDK_PATH = "${wasiSdk}";
      # x.py runs the freshly-built stage2 rustc, which has no rpath for
      # zlib/libstdc++ until autoPatchelf fixes the output, so expose them here.
      LD_LIBRARY_PATH = lib.makeLibraryPath [zlib stdenv.cc.cc.lib];
    };

    # Apply the fork's LLVM patch (build-wasix.sh step 1), install the vendor
    # config, and create the ./vendor symlink bootstrap's vendor check insists on
    # (a presence check only; resolution goes through the config's absolute dirs).
    postPatch = ''
      patchShebangs src/etc x.py configure
      ( cd src/llvm-project && patch -p1 < ../../wasix-llvm.patch )
      mkdir -p .cargo
      cp ${vendor.cargoConfig} .cargo/config.toml
      ln -s ${vendor.cratesIoVendor} vendor
    '';

    # Drive rust's own ./configure, encoding config.toml.wasix-template: the wasix
    # std target(s) mapped to the EH (and optionally EH+PIC) sysroots, in-tree
    # LLVM, stage0 = our bootstrap.
    configurePlatforms = [];
    configureFlags =
      [
        # NIGHTLY, not stable: the wasix target needs rustc's unstable wasm support
        # (threads/atomics), and only off-stable does rustc emit `--max-memory` for
        # the shared (threaded) memory. On stable the memory comes out non-growable,
        # the first std-startup allocation traps, and the program _Exit(70)s before
        # main. Upstream's template also leaves the channel non-stable.
        "--release-channel=nightly"
        "--build=${hostTriple}"
        "--host=${hostTriple}"
        "--target=${hostTriple},wasm32-wasmer-wasi${optionalString withDynamicLinking ",wasm32-wasmer-wasi-dl"}"
        "--set=build.rustc=${bootstrap}/bin/rustc"
        "--set=build.cargo=${bootstrap}/bin/cargo"
        "--enable-extended"
        "--tools=cargo"
        "--set=rust.lld=true"
        "--set=rust.llvm-tools=true"
        # Link the host rustc/cargo via the nix cc-wrapper (embeds an rpath to zlib
        # etc.) and keep rpaths, so the built binaries run outside the sandbox.
        "--enable-rpath"
        "--set=target.${hostTriple}.cc=${stdenv.cc}/bin/cc"
        "--set=target.${hostTriple}.cxx=${stdenv.cc}/bin/c++"
        "--set=target.${hostTriple}.linker=${stdenv.cc}/bin/cc"
        "--set=llvm.download-ci-llvm=false"
        "--set=llvm.ninja=true"
        "--set=target.wasm32-wasmer-wasi.wasi-root=${wasixSysrootEh}"
        # Pure-Rust compiler-builtins for the wasm targets (as nixpkgs does for
        # wasm32-unknown-unknown); otherwise the `c` feature pulls in cc-rs, and
        # the builtins come from the sysroot's libclang_rt anyway.
        "--set=target.wasm32-wasmer-wasi.optimized-compiler-builtins=false"
        "--disable-docs"
      ]
      ++ optionals withDynamicLinking [
        "--set=target.wasm32-wasmer-wasi-dl.wasi-root=${wasixSysrootEhpic}"
        "--set=target.wasm32-wasmer-wasi-dl.optimized-compiler-builtins=false"
      ];

    # cargo first, full stage 2 last: building cargo re-assembles the stage2
    # sysroot for the host only (dropping the wasm std), so the full build must
    # come after it. We copy stage2 directly instead of `x.py install`, which on
    # a non-git source builds the plain-source tarball, re-vendoring
    # src/tools/cargo, which fails offline.
    buildPhase = ''
      runHook preBuild
      python3 x.py build --stage 2 cargo
      python3 x.py build --stage 2
      runHook postBuild
    '';

    # cargo is a ToolRustc, so `--stage 2 cargo` lands its binary in
    # stage1-tools-bin/, outside the stage2 sysroot: copy it in. stage2 also
    # leaves lib/rustlib/{src,rustc-src}/rust as symlinks into the build dir,
    # which would dangle in $out; drop them (release artifacts omit them too).
    installPhase = ''
      runHook preInstall
      mkdir -p "$out"
      cp -a "build/${hostTriple}/stage2/." "$out/"
      install -Dm755 "build/${hostTriple}/stage1-tools-bin/cargo" "$out/bin/cargo"
      rm -rf "$out/lib/rustlib/src" "$out/lib/rustlib/rustc-src"
      runHook postInstall
    '';

    # Metadata so this can stand in as the `rustc` of a makeRustPlatform without
    # tripping buildRustPackage's rustc.targetPlatforms lookups. A wasix build
    # through buildRustPackage's cross path still needs the linker handled as
    # cargo-wasix does (rustc's self-contained wasm-ld, not the cross cc-wrapper).
    passthru = {
      targetPlatforms = lib.platforms.all;
      tier1TargetPlatforms = lib.platforms.all;
      badTargetPlatforms = [];
      # Profiles this toolchain built std for: eh, plus ehpic when
      # withDynamicLinking. set/rust-platform.nix injects this as the default
      # passthru.wasix.supportedProfiles of wasix Rust packages, so the overlay
      # marks them unsupported in the profiles rust can't target (off/exnref*).
      supportedProfiles = ["eh"] ++ optionals withDynamicLinking ["ehpic"];

      updateScript = nix-update-script {extraArgs = ["--flake"];};
    };

    meta = with lib; {
      description = "WASIX Rust toolchain (rustc + cargo + wasix std), built from source";
      homepage = "https://github.com/wasix-org/rust";
      license = with licenses; [mit asl20];
      platforms = ["x86_64-linux"];
    };
  }
