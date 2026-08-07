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
  version = "2026-08-06.1+rust-1.97";

  hostTriple = "x86_64-unknown-linux-gnu";

  # Full git checkout, including the src/llvm-project submodule we build in-tree.
  src = fetchFromGitHub {
    owner = "wasix-org";
    repo = "rust";
    tag = "v${version}";
    fetchSubmodules = true;
    hash = "sha256-xJo/H+Im8pkr84FLil3K5ZJCvF3kb4M7zKhqfhyBPho=";
  };

  # stage0 bootstrap compiler: the upstream release pinned in src/stage0, which
  # x.py would otherwise download itself.
  bootstrap = stdenv.mkDerivation {
    pname = "rust-bootstrap";
    version = "1.96.0";
    src = fetchurl {
      url = "https://static.rust-lang.org/dist/2026-05-28/rust-1.96.0-${hostTriple}.tar.xz";
      hash = "sha256-wpUEdYOlYjjqBrQ/hJ9Lh3+hK/1McQP42adMlMnE4Qg=";
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

  # Offline cargo registry for every workspace x.py compiles. x.py builds several
  # workspaces, each with its own lockfile; fetchCargoVendor vendors exactly one,
  # so merge the four into a union lock (build-time, from the fetched src, so no
  # import-from-derivation) and vendor that. fetchCargoVendor keys crates by
  # source, so it splits the two `libc 0.2.183` entries (the WASIX git fork that
  # std links, the registry copy the host tools use) into separate dirs on its
  # own; that split is why a single `cargo vendor` / `x vendor` refuses this tree.
  #
  # The library lock is the one libc-patch-crates-io.patch rewrites, so patch it
  # here too, matching what postPatch applies to the build; both read the same
  # patch, so they can't drift.
  mergedCargoLock =
    runCommand "wasix-rust-merged-cargo-lock" {
      nativeBuildInputs = [python3];
    } ''
      mkdir -p work/library/std "$out"
      cp ${src}/library/Cargo.lock work/library/Cargo.lock
      cp ${src}/library/Cargo.toml work/library/Cargo.toml
      cp ${src}/library/std/Cargo.toml work/library/std/Cargo.toml
      chmod -R +w work/library
      python3 ${./merge-cargo-locks.py} "$out/Cargo.lock" \
        ${src}/Cargo.lock \
        work/library/Cargo.lock \
        ${src}/src/tools/cargo/Cargo.lock \
        ${src}/src/bootstrap/Cargo.lock
    '';

  cargoVendorDir = rustPlatform.fetchCargoVendor {
    name = "wasix-rust-toolchain-${version}-vendor";
    src = mergedCargoLock;
    hash = "sha256-OQVUl9p5sT7nLgmxHqOspqUtKId50L3sJ1t0Je7gq58=";
  };

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
      # Binaries made during the build run without store rpaths (autoPatchelf
      # only fixes the output): stage2 rustc needs zlib/libstdc++, and since
      # 1.96 the bootstrap tool links liblzma.
      LD_LIBRARY_PATH = lib.makeLibraryPath [zlib xz stdenv.cc.cc.lib];
    };

    # Apply the fork's LLVM patch (build-wasix.sh step 1), install the vendor
    # config, and create the ./vendor symlink bootstrap's vendor check insists on
    # (a presence check only; resolution goes through the config's absolute dirs).
    postPatch = ''
      patchShebangs src/etc x.py configure
      ( cd src/llvm-project && patch -p1 < ../../wasix-llvm.patch )
      # Install fetchCargoVendor's source-replacement config with @vendor@ bound
      # to the vendor dir (what cargoSetupHook does for buildRustPackage).
      mkdir -p .cargo
      substitute ${cargoVendorDir}/.cargo/config.toml .cargo/config.toml \
        --subst-var-by vendor ${cargoVendorDir}
      ln -s ${cargoVendorDir} vendor
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
        # On since 1.96 in configure's default (dist) profile; without
        # build.vendor (see CARGO_NET_OFFLINE above) bootstrap then scans
        # $CARGO_HOME/registry/src, which the sandbox doesn't have, and panics.
        "--set=rust.remap-debuginfo=false"
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

    # cargo is a ToolRustc built with the stage-1 compiler, so it lands in a
    # tools-bin dir outside the stage2 sysroot: copy it in. Since 1.96 that dir
    # is named for build_compiler.stage + 1 (stage2-tools-bin), where 1.90
    # named it for the stage itself (stage1-tools-bin). stage2 also leaves
    # lib/rustlib/{src,rustc-src}/rust as symlinks into the build dir, which
    # would dangle in $out; drop them (release artifacts omit them too).
    installPhase = ''
      runHook preInstall
      mkdir -p "$out"
      cp -a "build/${hostTriple}/stage2/." "$out/"
      install -Dm755 "build/${hostTriple}/stage2-tools-bin/cargo" "$out/bin/cargo"
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

      # The updater builds this FOD alone with a fake hash to obtain the hash
      # for the new tag without scheduling the full toolchain.
      inherit cargoVendorDir;

      # Bumps, then re-derives the stage0 bootstrap pin and cargo vendor hash
      # from the new tag (the nix-update command is passed through as its argv).
      updateScript = ["pkgs/toolchain/rust/update.py"] ++ nix-update-script {extraArgs = ["--flake"];};
    };

    meta = with lib; {
      description = "WASIX Rust toolchain (rustc + cargo + wasix std), built from source";
      homepage = "https://github.com/wasix-org/rust";
      license = with licenses; [mit asl20];
      platforms = ["x86_64-linux"];
    };
  }
