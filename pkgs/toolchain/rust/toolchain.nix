# The WASIX Rust toolchain (wasix-org/rust), built from source: `x.py build
# --stage 2` for the host plus the wasix std targets, mirroring upstream's
# build-wasix.sh + config.toml.wasix-template:
#   - LLVM is built in-tree (download-ci-llvm = false) after applying
#     wasix-llvm.patch, which carries the fork's WebAssembly lowering; a stock
#     nixpkgs LLVM can't substitute.
#   - the two std targets use the EH and EH+PIC libc sysroots (wasi-root), like
#     SYSROOT_EH / SYSROOT_EHPIC in build-wasix.sh.
#   - stage0 is the upstream rustc/cargo pinned in src/stage0 (1.96.0); the fork
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
  perl,
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
  wasixcc,
  wasixSysrootEh,
  wasixSysrootEhpic,
  # The central WASIX crate-edit pipeline, shared with set/rust-platform.nix.
  patchVendor,
  # Also build std for wasm32-wasmer-wasi-dl (the dynamic-linking / PIC target),
  # needed for PIC `.so` Rust artifacts (e.g. pyo3 python extensions).
  withDynamicLinking ? true,
  # Build rustc/cargo to run on WASIX. Bootstrap executes only native compilers;
  # the resulting stage-2 compiler and its LLVM backend are WASIX modules.
  hostedOnWasix ? false,
}: let
  inherit (lib) optionals optionalString;
  version = "2026-08-06.1+rust-1.97";

  buildTriple = "x86_64-unknown-linux-gnu";
  hostTriple =
    if hostedOnWasix
    then "wasm32-wasmer-wasi"
    else buildTriple;
  targetTriples =
    if hostedOnWasix
    then hostTriple
    else "${hostTriple},wasm32-wasmer-wasi${optionalString withDynamicLinking ",wasm32-wasmer-wasi-dl"}";
  executableSuffix = optionalString hostedOnWasix ".wasm";

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
      url = "https://static.rust-lang.org/dist/2026-05-28/rust-1.96.0-${buildTriple}.tar.xz";
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
        --components=rustc,cargo,rust-std-${buildTriple}
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

  rawCargoVendorDir = rustPlatform.fetchCargoVendor {
    name = "wasix-rust-toolchain-${version}-vendor";
    src = mergedCargoLock;
    hash = "sha256-OQVUl9p5sT7nLgmxHqOspqUtKId50L3sJ1t0Je7gq58=";
  };
  cargoVendorDir =
    if hostedOnWasix
    then patchVendor rawCargoVendorDir
    else rawCargoVendorDir;

  # rust bootstrap's cc_detect.rs looks for a `-wasi` target's C compiler at
  # $WASI_SDK_PATH/bin/<target>-clang[++]. Delegate those names to wasixcc so
  # profile-specific TLS, exception, sysroot, and linker flags stay canonical.
  wasiSdk = let
    env = import ../env.nix {inherit lib;};
    mkClang = triple: pic: let
      profileEnv = env.exportsOf (
        env.profileEnv {
          wasmExceptions = "legacy";
          inherit pic;
        }
        // {
          WASIXCC_DISCARD_UNSUPPORTED_FLAGS = "yes";
          WASIXCC_RUN_WASM_OPT = "no";
        }
      );
    in ''
      for lang in clang clang++; do
        tool=wasixcc
        if [ "$lang" = clang++ ]; then
          tool=wasix++
        fi
        target="$out/bin/${triple}-$lang"
        printf '#!%s\n%s\nargs=()\nfor arg in "$@"; do\n  case "$arg" in -fno-exceptions|-fno-cxx-exceptions) ;; *) args+=("$arg");; esac\ndone\nexec "%s/bin/%s" "''${args[@]}"\n' \
          "${stdenv.shell}" ${lib.escapeShellArg profileEnv} "${wasixcc}" "$tool" > "$target"
        chmod +x "$target"
      done
    '';
  in
    runCommand "wasix-wasi-sdk" {} ''
      mkdir -p "$out/bin"
      ${mkClang "wasm32-wasmer-wasi" false}
      ${mkClang "wasm32-wasmer-wasi-dl" true}
    '';
in
  stdenv.mkDerivation {
    pname = "wasix-rust-toolchain";
    inherit version src;

    patches = optionals hostedOnWasix [
      ./wasix-host-tools.patch
      ./wasix-process-fds.patch
      ./tool-atomic-wait-feature.patch
    ];

    nativeBuildInputs =
      [
        python3
        perl
        cmake
        ninja
        pkg-config
        which
        file
      ]
      # clang resolves to its unwrapped output, so its sibling lookup cannot see
      # wasm-ld from the combined tree. Keep that tree on PATH while cross-linking
      # the target LLVM backend and rustc.
      ++ optionals hostedOnWasix [wasixLlvm]
      # Native rustc/cargo need store rpaths. WASIX modules do not use ELF
      # rpaths and must not be passed to autoPatchelf.
      ++ optionals (!hostedOnWasix) [autoPatchelfHook]
      ++ [writableTmpDirAsHomeHook];

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
    dontStrip = hostedOnWasix;
    enableParallelBuilding = true;
    requiredSystemFeatures = ["big-parallel"];

    env =
      {
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
      }
      // lib.optionalAttrs hostedOnWasix {
        # The target Cargo must not accept nixpkgs' build-machine libcurl through
        # the pkg-config wrapper. curl-sys' bundled source is compiled by wasixcc.
        LIBCURL_NO_PKG_CONFIG = "1";
      };

    # Apply the fork's LLVM patch (build-wasix.sh step 1), install the vendor
    # config, and create the ./vendor symlink bootstrap's vendor check insists on
    # (a presence check only; resolution goes through the config's absolute dirs).
    postPatch = ''
      patchShebangs src/etc x.py configure
      ( cd src/llvm-project && patch -p1 < ../../wasix-llvm.patch )
      ${optionalString hostedOnWasix ''
        # Same WASIX support constraints as overlay/packages/llvm, adjusted for
        # this newer in-tree LLVM revision and bootstrap's Generic CMake target.
        ( cd src/llvm-project/llvm && patch -p1 < ${./llvm-wasix-host.patch} )
        ( cd src/llvm-project/lld && patch -p1 < ${./lld-wasix-host.patch} )
      ''}
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
        "--build=${buildTriple}"
        "--host=${hostTriple}"
        "--target=${targetTriples}"
        "--set=build.rustc=${bootstrap}/bin/rustc"
        "--set=build.cargo=${bootstrap}/bin/cargo"
        "--enable-extended"
        "--tools=cargo"
        # The WASIX target selects the self-contained linker flavor, including
        # while bootstrap links the hosted Cargo binary.
        "--set=rust.lld=true"
        "--set=rust.llvm-tools=${
          if hostedOnWasix
          then "false"
          else "true"
        }"
        # Link the host rustc/cargo via the nix cc-wrapper (embeds an rpath to zlib
        # etc.) and keep rpaths, so the built binaries run outside the sandbox.
        "--enable-rpath"
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
      ++ optionals (!hostedOnWasix) [
        "--set=target.${hostTriple}.cc=${stdenv.cc}/bin/cc"
        "--set=target.${hostTriple}.cxx=${stdenv.cc}/bin/c++"
        "--set=target.${hostTriple}.linker=${stdenv.cc}/bin/cc"
      ]
      ++ optionals hostedOnWasix [
        # This setting is global: native bootstrap needs X86 while the hosted
        # compiler needs WebAssembly. No other backend is used.
        "--set=llvm.targets=X86;WebAssembly"
        "--set=llvm.experimental-targets="
        "--set=target.${hostTriple}.cc=${wasiSdk}/bin/${hostTriple}-clang"
        "--set=target.${hostTriple}.cxx=${wasiSdk}/bin/${hostTriple}-clang++"
        "--set=target.${hostTriple}.linker=${wasiSdk}/bin/${hostTriple}-clang++"
        "--set=target.${hostTriple}.wasi-root=${wasixSysrootEh}"
        "--set=target.${hostTriple}.optimized-compiler-builtins=false"
      ]
      ++ optionals (withDynamicLinking && !hostedOnWasix) [
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
      python3 x.py build --stage ${
        if hostedOnWasix
        then "1"
        else "2"
      } cargo
      ${
        if hostedOnWasix
        then "python3 x.py build --stage 2 compiler/rustc"
        else "python3 x.py build --stage 2"
      }
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
      cargo=$(find build -type f -path '*/stage2-tools-bin/cargo${executableSuffix}' | head -n 1)
      test -n "$cargo"
      install -Dm755 "$cargo" "$out/bin/cargo${executableSuffix}"
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

      # The vendor FOD under the name nix-update looks for, so a bump re-derives
      # its hash (cargoDeps.vendorStaging) without scheduling the full toolchain.
      cargoDeps = cargoVendorDir;

      # Bumps, then re-derives the stage0 bootstrap pin from the new tag (the
      # nix-update command is passed through as its argv).
      updateScript = ["pkgs/toolchain/rust/update.py"] ++ nix-update-script {extraArgs = ["--flake"];};
      wasix.updateNotes = optionals hostedOnWasix [
        {message = "wasix-host-tools.patch enables the WASIX host target, supplies Cargo's WASIX process/path branches, and disables SSH until target OpenSSL exists; recheck on the next tag bump";}
        {message = "wasix-process-fds.patch implements WASIX child pipe descriptor conversions in std; recheck on the next tag bump";}
        {message = "llvm-wasix-host.patch carries WASIX host portability fixes for Rust's in-tree LLVM; recheck it on the next tag bump";}
        {message = "lld-wasix-host.patch works around wasix-libc declaring POSIX_MADV_WILLNEED without exporting posix_madvise; recheck it on the next tag bump";}
        {message = "the central filetime, getrandom, home, jobserver, curl, curl-sys, git2, gix-fs, gix-index, gix-pack, libgit2-sys, libloading, and openssl-src floor patches are needed by WASIX-hosted tools; recheck them on the next tag bump";}
      ];
    };

    meta = with lib; {
      description =
        if hostedOnWasix
        then "WASIX-hosted Rust toolchain (rustc + cargo + WASIX std), built from source"
        else "WASIX Rust toolchain (rustc + cargo + wasix std), built from source";
      homepage = "https://github.com/wasix-org/rust";
      license = with licenses; [mit asl20];
      platforms = ["x86_64-linux"];
    };
  }
