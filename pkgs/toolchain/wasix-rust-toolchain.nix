# Build the WASIX Rust toolchain FROM SOURCE (wasix-org/rust), the upstream way:
# `x.py build --stage 2` for the host plus the two wasix std targets, against the
# from-source wasix-libc sysroots. Replaces the old prebuilt-tarball download.
#
# Mirrors wasix-org/rust's build-wasix.sh + config.toml.wasix-template + CI:
#   - bundled LLVM is built in-tree (download-ci-llvm = false) after applying
#     wasix-llvm.patch — that patch carries the WebAssembly lowering the fork needs,
#     so we can't substitute a stock nixpkgs LLVM here.
#   - the two std targets map to the EH and EH+PIC libc sysroots (wasi-root), exactly
#     like SYSROOT_EH / SYSROOT_EHPIC in build-wasix.sh.
#   - stage0 is the official upstream rustc/cargo pinned in src/stage0 (1.89.0); the
#     fork can only be bootstrapped by its immediate predecessor, so nixpkgs' much
#     newer rustc can't stand in.
#
# The output is the linked stage2 tree (bin/{rustc,cargo,…} + lib/rustlib/…), the
# same layout the release tarball shipped, so cargo-wasix.nix consumes it unchanged.
{
  lib,
  stdenv,
  fetchFromGitHub,
  fetchurl,
  runCommand,
  linkFarm,
  formats,
  rustPlatform,
  autoPatchelfHook,
  # Sets HOME to a writable temp dir for the build (x.py/cargo write to ~/.cargo etc.).
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
  # From-source wasix LLVM (clang/lld) + the EH and EH+PIC libc sysroots (wasix-next).
  wasixLlvm,
  wasixSysrootEh,
  wasixSysrootEhpic,
  # Also build std for wasm32-wasmer-wasi-dl (the dynamic-linking / PIC target),
  # needed for PIC `.so` Rust artifacts (e.g. pyo3 python extensions).
  #
  # An earlier note claimed the fork's cc-rs rejects the `-dl` ABI during compiler
  # detection. That's stale: src/bootstrap pins cc-rs f2e7d1a1, which is the commit
  # that *added* the `dl` env arm — it parses wasm32-wasmer-wasi-dl cleanly (the
  # `wasi` OS rule then blanks the env, so bootstrap's flag-probe clang just sees
  # --target=wasm32-wasmer-wasi). The library/ (std) workspace pins stock cc 1.2.0
  # without that arm, but with optimized-compiler-builtins=false (below) and no
  # profiler_builtins, the std build never invokes cc for the wasm target, so its
  # parser is never exercised on `-dl`. Both sysroots (eh / ehpic) and the per-target
  # WASI-SDK clang wrappers are already wired, so the `-dl` std target just builds.
  withDynamicLinking ? true,
}: let
  inherit (lib) optionals optionalString;
  # Fork release tag. `+` is part of the tag; fetchFromGitHub takes it verbatim.
  version = "v2026-02-09.1+rust-1.90";

  hostTriple = "x86_64-unknown-linux-gnu";

  # Full git checkout, including the src/llvm-project submodule we build in-tree.
  src = fetchFromGitHub {
    owner = "wasix-org";
    repo = "rust";
    rev = version;
    fetchSubmodules = true;
    hash = "sha256-IpYgSk8ijtUcGQVZCR64rWmiF0bGgYsIN+7cX9TgyW0=";
  };

  # stage0 bootstrap compiler: the exact upstream release pinned in src/stage0
  # (compiler_date / compiler_version). x.py would otherwise download this itself.
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
      # The release installer's scripts use `#!/usr/bin/env`, absent in the sandbox.
      patchShebangs install.sh
      ./install.sh \
        --prefix="$out" \
        --disable-ldconfig \
        --components=rustc,cargo,rust-std-${hostTriple}
      runHook postInstall
    '';
  };

  # Offline cargo registry for every workspace x.py compiles — the compiler/tools
  # (root), std (library), the cargo tool, and bootstrap. Each is a separate cargo
  # workspace with its own lockfile, so we vendor each with importCargoLock (reads the
  # already-resolved entries — no re-resolution of the [patch.crates-io] forks, no
  # vendor-wide FOD hash) and assemble one source-replacement config that x.py's single
  # root .cargo/config.toml hands to all of them. Stock rust ships this prebuilt as the
  # release tarball's vendor/; the fork ships only a git tag, so we reconstruct it.
  #
  # The crates come from two source kinds: crates-io and the wasix git forks (cc-rs,
  # libc). name+version is NOT unique across them — cc 1.2.27 is the dl-arm fork (the
  # git pin that teaches cc-rs the `wasm32-wasmer-wasi-dl` ABI) in src/bootstrap but
  # stock crates-io in src/tools/cargo. cargo keeps git+… and registry+… as distinct
  # sources, each with its own checksum, so this is legal — but a `directory` source is
  # keyed by name+version alone. Collapsing both into one vendored dir would force a
  # single cc-1.2.27 and silently serve one lockfile the other's crate (e.g. cargo
  # compiling fork code under stock's `d487aa…` checksum). So vendor the two source
  # kinds into separate directories and replace each source with the directory holding
  # ITS crates: every crate served from exactly the source its lockfile names.
  #
  # It's all derived from the lockfiles in Nix — fromTOML to classify by source,
  # linkFarm for the trees (attrset keys dedupe across lockfiles; same source+version is
  # identical content), formats.toml to serialise the config. No shell.
  lockFiles = map (p: "${src}/${p}") [
    "Cargo.lock"
    "library/Cargo.lock"
    "src/tools/cargo/Cargo.lock"
    "src/bootstrap/Cargo.lock"
  ];
  # The cc-rs / libc forks are pinned by commit, so builtins.fetchGit is pure.
  vendorOf = lf:
    rustPlatform.importCargoLock {
      lockFile = lf;
      allowBuiltinFetchGit = true;
    };
  packagesOf = lf: (builtins.fromTOML (builtins.readFile lf)).package or [];
  isGitSource = source: lib.hasPrefix "git+" source;

  # name-version → its vendored-crate subpath, for every package whose source matches
  # `pred`, unioned across all lockfiles. importCargoLock names each crate dir
  # "<name>-<version>"; workspace members carry no `source` and aren't vendored.
  vendorTree = pred:
    lib.listToAttrs (lib.concatMap (
        lf: let
          v = vendorOf lf;
        in
          map (p: lib.nameValuePair "${p.name}-${p.version}" "${v}/${p.name}-${p.version}")
          (lib.filter (p: (p ? source) && pred p.source) (packagesOf lf))
      )
      lockFiles);

  cratesIoVendor = linkFarm "wasix-rust-vendor" (vendorTree (s: !isGitSource s));
  gitVendor = linkFarm "wasix-rust-vendor-git" (vendorTree isGitSource);

  # One [source."git+…"] entry per distinct git source: define it (cargo needs the git
  # url + ref to identify the source) and replace it with the git vendor dir. The source
  # id encodes url + ref + rev, so we read those back out of it.
  gitSourceEntry = source: let
    m = builtins.match ''git\+([^?#]+)(\?(rev|tag|branch)=([^#]+))?#(.+)'' source;
    refKind = lib.elemAt m 2;
  in
    lib.nameValuePair source ({
        git = lib.elemAt m 0;
        replace-with = "vendored-git";
      }
      // (
        if refKind != null
        then {${refKind} = lib.elemAt m 3;}
        else {rev = lib.elemAt m 4;}
      ));
  gitSources = lib.unique (lib.concatMap (
      lf: map (p: p.source) (lib.filter (p: (p ? source) && isGitSource p.source) (packagesOf lf))
    )
    lockFiles);

  cargoConfig = (formats.toml {}).generate "wasix-rust-cargo-config.toml" {
    source =
      {
        crates-io.replace-with = "vendored-sources";
        vendored-sources.directory = "${cratesIoVendor}";
        vendored-git.directory = "${gitVendor}";
      }
      // lib.listToAttrs (map gitSourceEntry gitSources);
  };

  # rust bootstrap's cc_detect.rs locates the C compiler for a `-wasi` target at
  # $WASI_SDK_PATH/bin/<target>-clang[++] (see src/bootstrap/src/utils/cc_detect.rs).
  # Upstream's build environment supplies that; we synthesize an equivalent from the
  # from-source wasix clang + the matching per-variant sysroot (eh for the base target,
  # ehpic + -fPIC for the -dl target).
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
      # Patch the built rustc/cargo binaries so they find zlib/libstdc++ at runtime
      # (x.py's own linking doesn't embed a store rpath for them).
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

    # Static build env (eval-time-known, so declarative here rather than `export`ed in
    # buildPhase). HOME stays a buildPhase export — it needs $TMPDIR, a build-time path.
    env = {
      # Rust bootstrap special-cases CI environments; force it off.
      GITHUB_ACTIONS = "false";
      # Resolve deps from the vendored sources only. We don't set build.vendor (that
      # forces cargo --frozen, which trips over the fork's slightly stale lockfiles);
      # offline mode still bars the network but lets cargo refresh a lock in place.
      CARGO_NET_OFFLINE = "true";
      # The wasix C toolchain for the std targets' C compiler detection (cc_detect.rs).
      WASI_SDK_PATH = "${wasiSdk}";
      # x.py runs the freshly-built stage2 rustc during the build; until autoPatchelf
      # fixes the output it has no rpath for zlib/libstdc++, so expose them here. The
      # sandbox starts with LD_LIBRARY_PATH unset, so no need to preserve a prior value.
      LD_LIBRARY_PATH = lib.makeLibraryPath [zlib stdenv.cc.cc.lib];
    };

    # patchShebangs; apply the fork's LLVM WebAssembly-lowering patch (build-wasix.sh
    # step 1); then drop the source-replacement .cargo/config.toml (crates-io + the
    # cc-rs/libc git forks), plus the ./vendor symlink at the root that bootstrap's
    # vendor check insists on (resolution is via the config's absolute dirs; this is
    # just a presence check, so the crates-io tree suffices).
    postPatch = ''
      patchShebangs src/etc x.py configure
      ( cd src/llvm-project && patch -p1 < ../../wasix-llvm.patch )
      mkdir -p .cargo
      cp ${cargoConfig} .cargo/config.toml
      ln -s ${cratesIoVendor} vendor
    '';

    # Drive rust's own ./configure (the nix-idiomatic path; it generates bootstrap.toml
    # for us). Encodes config.toml.wasix-template's intent: host + the wasix std
    # target(s) mapped to the EH (and optionally EH+PIC) sysroots, in-tree LLVM,
    # stage0 = our bootstrap.
    configurePlatforms = [];
    configureFlags =
      [
        # NIGHTLY, not stable. The wasm32-wasmer-wasi target needs rustc's *unstable*
        # wasm support (threads/atomics), and rustc only emits `--max-memory=4 GiB` for
        # a shared (threaded) memory off the stable channel. On `stable` that flag is
        # gated off, so the shared memory comes out non-growable (max == initial); the
        # heap can't grow and the first allocation in std startup traps → the program
        # _Exit(70)s before main ("Rust builds but doesn't run"). Upstream's
        # config.toml.wasix-template leaves the channel at its non-stable default;
        # forcing stable here was the bug. (cargo-wasix's prebuilt path always worked
        # because its toolchain is non-stable and so emits the flag natively.)
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
        # Build compiler-builtins as pure Rust (no C intrinsics) for the wasm targets,
        # the same as nixpkgs does for wasm32-unknown-unknown. Otherwise
        # compiler_builtins' `c` feature pulls in cc-rs (the builtins themselves come
        # from the sysroot's libclang_rt anyway).
        "--set=target.wasm32-wasmer-wasi.optimized-compiler-builtins=false"
        "--disable-docs"
      ]
      ++ optionals withDynamicLinking [
        "--set=target.wasm32-wasmer-wasi-dl.wasi-root=${wasixSysrootEhpic}"
        "--set=target.wasm32-wasmer-wasi-dl.optimized-compiler-builtins=false"
      ];

    # Build cargo first, then rustc + std last. Building cargo re-assembles the stage2
    # sysroot for the host only (dropping the wasm std), so the full `x.py build --stage 2`
    # must run after it to leave the sysroot with std for every target; cargo's own binary
    # (stage1-tools-bin) is unaffected by the second build. We copy the stage2 tree directly
    # rather than `x.py install`, which on a non-git source insists on building the
    # plain-source tarball — re-vendoring src/tools/cargo, which fails offline.
    buildPhase = ''
      runHook preBuild
      python3 x.py build --stage 2 cargo
      python3 x.py build --stage 2
      runHook postBuild
    '';

    # stage2/ is the rustc sysroot (rustc + std + bundled rust-lld). cargo is a ToolRustc,
    # built with the previous-stage compiler, so `--stage 2 cargo` lands its binary in
    # stage1-tools-bin/ (verified), outside the sysroot — copy it in. stage2 also leaves
    # lib/rustlib/{src,rustc-src}/rust as symlinks into the build's source dir, which would
    # dangle in $out, so drop them (the release artifact omits them too).
    installPhase = ''
      runHook preInstall
      mkdir -p "$out"
      cp -a "build/${hostTriple}/stage2/." "$out/"
      install -Dm755 "build/${hostTriple}/stage1-tools-bin/cargo" "$out/bin/cargo"
      rm -rf "$out/lib/rustlib/src" "$out/lib/rustlib/rustc-src"
      runHook postInstall
    '';

    # Metadata so this can stand in as the `rustc` of a `makeRustPlatform` (e.g.
    # `makeRustPlatform { rustc = wasixRustToolchain; cargo = …; }`) without tripping
    # buildRustPackage's `rustc.targetPlatforms` lookups. Note: driving a wasix build
    # through buildRustPackage's cross path still needs the linker handled the way
    # cargo-wasix does (rustc's self-contained wasm-ld, not the cross cc-wrapper).
    passthru = {
      targetPlatforms = lib.platforms.all;
      tier1TargetPlatforms = lib.platforms.all;
      badTargetPlatforms = [];
      # The ABI variants this toolchain built std for (and can thus target). Only
      # eh (wasm32-wasmer-wasi); the -dl/ehpic target rides on withDynamicLinking.
      # Consumed by the wasix overlay to mark Rust packages broken in the variants
      # rust can't target (off/exnref*), giving a clear error instead of a missing
      # rustPlatform.
      supportedVariants = ["eh"] ++ optionals withDynamicLinking ["ehpic"];
    };

    meta = with lib; {
      description = "WASIX Rust toolchain (rustc + cargo + wasix std), built from source";
      homepage = "https://github.com/wasix-org/rust";
      license = with licenses; [mit asl20];
      platforms = ["x86_64-linux"];
    };
  }
