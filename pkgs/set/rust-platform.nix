# Rust counterpart to set/stdenv.nix: the profile's rustPlatform, built with a
# `cargo` shim that routes `cargo build` through cargo-wasix (which does the
# wasm-opt EH->exnref pass + target-features), so buildRustPackage works unchanged.
{
  lib,
  pkgsCross,
  wasixRustToolchain,
  wasixcc,
  cargo,
  cargoWasix,
  # toolchain.binaryen, not pkgsCross.buildPackages.binaryen: the wheel .so pass
  # has to parse the same +wide-arithmetic output cargo-wasix's wasm-opt does.
  binaryen,
  # crate-edits.nix view, baked into vendored sources at vendor time.
  crateEdits,
}: let
  hostPkgs = pkgsCross.buildPackages;
  # Vendoring runs host-side metadata operations and must not pull in the WASIX toolchain.
  vendorPlatform = hostPkgs.rustPlatform;
  # the toolchain's build-host rust triple; derive it so it can't drift.
  hostTriple = hostPkgs.stdenv.hostPlatform.rust.rustcTarget;
  rustLld = "${wasixRustToolchain}/lib/rustlib/${hostTriple}/bin/rust-lld";

  # cc-rs (a dependency's build.rs compiling a vendored C library, e.g. ring's
  # BoringSSL) resolves the compiler from CC_<target>, defaulting to the nix cc
  # wrapper, which rejects the `-dl` rustc target triple and the PIC-without-EH
  # combination cc-rs derives from cargo's relocation-model. Point it at wasixcc
  # instead, with the same profile the `-dl` std is built at (toolchain.nix:
  # mkClang "wasm32-wasmer-wasi-dl" wasixSysrootEhpic "-fPIC" == the ehpic
  # profile); the shared exnref hook translates the linked .so afterwards, so
  # the C objects match the rust ones. Sourced from the profile table, not
  # hand-typed; WASIXCC_* comes from toolchain/env.nix, never hand-written.
  env = import ../toolchain/env.nix {inherit lib;};
  dlProfile = (import ../profiles.nix).profiles.ehpic;
  depCcEnv = env.exportsOf (env.profileEnv {
    inherit (dlProfile) wasmExceptions;
    pic = dlProfile.wasmPic or false;
  });
  # cc-rs unconditionally passes -fno-exceptions (and -fno-rtti for C++); wasixcc
  # rejects those with PIC, which needs wasm EH (same reason crc32c.nix seds them
  # out of its cmake build). Drop them so WASIXCC_WASM_EXCEPTIONS stands.
  mkDepCc = binName: tool:
    pkgsCross.buildPackages.writeShellScriptBin binName ''
      ${depCcEnv}
      args=()
      for a in "$@"; do
        case "$a" in
          -fno-exceptions | -fno-rtti) ;;
          *) args+=("$a") ;;
        esac
      done
      exec ${wasixcc}/bin/${tool} "''${args[@]}"
    '';
  depCc = pkgsCross.buildPackages.symlinkJoin {
    name = "wasix-dep-cc";
    paths = [
      (mkDepCc "cc" "wasixcc")
      (mkDepCc "c++" "wasix++")
    ];
  };
  # cc-rs also reads the dash triple with dashes replaced by underscores, the
  # only form bash can export.
  wasixDepCcHook =
    pkgsCross.makeSetupHook {name = "wasix-dep-cc-hook";}
    (pkgsCross.buildPackages.writeText "wasix-dep-cc-hook.sh" ''
      export CC_wasm32_wasmer_wasi_dl=${depCc}/bin/cc
      export CXX_wasm32_wasmer_wasi_dl=${depCc}/bin/c++
    '');

  # `cargo build` goes through cargo-wasix, everything else (metadata, etc.)
  # to the real cargo.
  cargoWasixCargo = pkgsCross.buildPackages.writeShellScriptBin "cargo" ''
    if [ "''${1-}" = build ]; then
      shift
      # cargo-wasix wants a writable HOME/RUSTUP_HOME for its rustup state.
      export HOME="$PWD/.home"
      export RUSTUP_HOME="$HOME/.rustup"
      mkdir -p "$HOME" "$RUSTUP_HOME"
      exec ${cargoWasix}/bin/cargo-wasix wasix build "$@"
    fi
    exec ${cargo}/bin/cargo "$@"
  '';

  base = pkgsCross.makeRustPlatform {
    rustc = wasixRustToolchain;
    cargo = cargoWasixCargo;
  };

  # maturin panics parsing the wasix `dl` triple; patchVendor adds the `dl`
  # variant to its own vendored target-lexicon (the same fork the wheels use).
  wasixMaturin = hostPkgs.maturin.overrideAttrs (old: {
    cargoDeps = patchInPlace old.cargoDeps;
  });

  # cargo-wasix runs `wasm-opt --translate-to-exnref` on the `.wasm` CLIs it
  # emits, converting the legacy Wasm-EH that rustc/LLVM and the rust target's
  # legacy-EH `-dl` sysroot libc++ produce into the exnref encoding wasmer
  # accepts. maturin drives `cargo rustc` itself and reads cargo's artifact
  # stream directly, so it never routes through cargo-wasix and its cdylib `.so`
  # keeps the legacy `try` (surfaces when the crate pulls libc++ exceptions, e.g.
  # tokenizers' esaxx-rs). A setup hook re-applies the same pass to every wheel
  # `.so`; it is a no-op on modules that already have no legacy EH. See
  # WASIX-TODO.md.
  exnrefTranslateHook =
    pkgsCross.makeSetupHook {
      name = "wasix-translate-exnref-hook";
      propagatedBuildInputs = [binaryen];
    }
    (pkgsCross.buildPackages.writeText "wasix-translate-exnref-hook.sh" ''
      _wasixTranslateSoToExnref() {
        local so
        while IFS= read -r -d "" so; do
          echo "wasix: translating $so to exnref EH"
          wasm-opt "$so" \
            --enable-bulk-memory --enable-threads --enable-reference-types \
            --enable-exception-handling --no-validation --translate-to-exnref \
            -o "$so.exnref"
          mv "$so.exnref" "$so"
        done < <(find "''${prefix:-$out}" -name '*.so' -type f -print0)
      }
      fixupOutputHooks+=(_wasixTranslateSoToExnref)
    '');

  # ── Vendored-crate patching ──────────────────────────────────────────────
  # The wasix rust builds carry their edits as source patches
  # (../lib/wasix-crate-patches), not `[patch.crates-io]`. Every build, CLI or
  # wheel, gets its crates through fetchCargoVendor/importCargoLock, so patchVendor
  # bakes the edits into that vendored tree at vendor time. It reads the vendor's
  # crate set at eval (an IFD on the vendor FOD), resolves each present crate
  # (crate-edits.nix), and applies it, so editing one crate's edits only rebuilds
  # vendors that contain it. See ../lib/wasix-crate-patches/README.md.
  startsWithDigit = s: builtins.match "[0-9].*" s != null;
  # Crate entries in a vendor tree, two layouts: fetchCargoVendor nests real dirs
  # under source-registry-0 (git deps under source-git-*), importCargoLock
  # symlinks each crate flat at the root. Collect every root entry plus the
  # children of real root subdirs, never following the crate symlinks.
  vendorCrateDirs = raw: let
    root = builtins.readDir raw;
    subdirs = lib.attrNames (lib.filterAttrs (_: t: t == "directory") root);
  in
    lib.attrNames root
    ++ lib.concatMap (d: lib.attrNames (builtins.readDir (raw + "/${d}"))) subdirs;

  # Covered edited crates present in a vendor, as {crate, version, resolved}. A
  # <crate>-<version> dir matches the edited crate that prefixes it, guarded by a
  # digit-starting suffix so tokio-util isn't taken for tokio. Its stateOf then
  # decides: edited -> patch, stock -> leave as-is, unsupported -> hard fail (a
  # version we have not vetted must not silently build unpatched).
  presentEdits = raw:
    lib.filter (e: e != null) (
      map (
        d: let
          crate =
            lib.findFirst (
              c: let
                v = lib.removePrefix "${c}-" d;
              in
                lib.hasPrefix "${c}-" d && startsWithDigit v
            )
            null
            crateEdits.crates;
        in
          if crate == null
          then null
          else let
            version = lib.removePrefix "${crate}-" d;
            state = crateEdits.stateOf crate version;
          in
            if state == "stock"
            then null
            else if state == "unsupported"
            then throw "wasix: ${crate} ${version} is unsupported (matches neither `edited` nor `stock` in wasix-crate-patches/${crate}/edits.nix); add it to `edited` (with a patch if needed) or to `stock`"
            else {
              inherit crate version;
              resolved = crateEdits.resolve crate version;
            }
      )
      (vendorCrateDirs raw)
    );

  # ── Added deps ───────────────────────────────────────────────────────────
  # An edit can pull in a crate upstream lacks (mio -> wasix). Injected post-FOD
  # so the cargoHash is untouched: the crate is dropped into the vendor with its
  # own fetchurl + lock line, and the build's source lock is amended to match
  # (wasixLockAmendHook), both via amend-lock.py so cargoSetupPostPatchHook's diff
  # passes. The crates.io checksum is the lock checksum, so no separate fetch hash.
  addsJson = hostPkgs.writeText "wasix-crate-adds.json" (builtins.toJSON crateEdits.adds);
  amendLockPy = ../lib/amend-lock.py;
  addsCratesDir = hostPkgs.runCommand "wasix-adds-crates" {} (
    lib.concatMapStrings (a: ''
      mkdir -p "$out"
      tar xzf ${hostPkgs.fetchurl {
        url = "https://static.crates.io/crates/${a.name}/${a.name}-${a.version}.crate";
        sha256 = a.checksum;
      }} -C "$out"
      printf '{"files":{},"package":"${a.checksum}"}' \
        > "$out/${a.name}-${a.version}/.cargo-checksum.json"
    '')
    crateEdits.adds
  );
  wasixLockAmendHook =
    pkgsCross.makeSetupHook {name = "wasix-lock-amend-hook";}
    (pkgsCross.buildPackages.writeText "wasix-lock-amend-hook.sh" ''
      _wasixAmendSourceLock() {
        local l="''${cargoRoot:+$cargoRoot/}Cargo.lock"
        [ -f "$l" ] || return 0
        ${hostPkgs.python3}/bin/python3 ${amendLockPy} "$l" ${addsJson} > "$l.wasix"
        mv "$l.wasix" "$l"
      }
      postPatchHooks=(_wasixAmendSourceLock ''${postPatchHooks[@]+"''${postPatchHooks[@]}"})
    '');

  # ── Apply ────────────────────────────────────────────────────────────────
  # Apply one resolved crate in place: materialize an importCargoLock symlink so
  # patch can write, apply the patch stack, run the phase, then empty the
  # per-file checksums while keeping the package checksum. cargo verifies the
  # package checksum against the lock (dropping it fails the build with "checksum
  # could not be calculated, but a checksum is listed"), and an empty file map
  # then lets the patched contents through without per-file tracking.
  applyOne = {
    crate,
    version,
    resolved,
  }: ''
    d=$(find "$out" -maxdepth 2 \( -type d -o -type l \) -name ${lib.escapeShellArg "${crate}-${version}"} | head -1)
    [ -n "$d" ] || { echo "wasix: ${crate}-${version} not in vendor" >&2; exit 1; }
    if [ -L "$d" ]; then t="$d.wasix-real"; cp -rL "$d" "$t"; rm "$d"; mv "$t" "$d"; chmod -R u+w "$d"; fi
    (
      cd "$d"
      ${lib.concatMapStrings (p: "patch -p1 --no-backup-if-mismatch < ${p}\n      ") resolved.patches}
      ${resolved.patchPhase}
      jq '.files = {}' .cargo-checksum.json > .cargo-checksum.json.w
      mv .cargo-checksum.json.w .cargo-checksum.json
    )
  '';

  injectAdds = presents: let
    need = lib.filter (a: lib.any (e: e.crate == a.crate) presents) crateEdits.adds;
  in
    lib.optionalString (need != []) (
      lib.concatMapStrings (a: ''
        if ! find "$out" -maxdepth 2 \( -type d -o -type l \) -name ${lib.escapeShellArg "${a.name}-*"} | grep -q .; then
          adder=$(find "$out" -maxdepth 2 -type d -name ${lib.escapeShellArg "${a.crate}-*"} -print -quit)
          [ -n "$adder" ] && cp -a ${addsCratesDir}/${a.name}-${a.version} "$(dirname "$adder")/"
        fi
      '')
      need
      + ''
        _l=$(find "$out" -maxdepth 2 -name Cargo.lock -print -quit)
        [ -n "$_l" ] && { ${hostPkgs.python3}/bin/python3 ${amendLockPy} "$_l" ${addsJson} > "$_l.w"; mv "$_l.w" "$_l"; }
      ''
    );

  applyPlan = presents:
    lib.optionalString (presents != []) (
      ''
        chmod -R u+w "$out"
      ''
      + lib.concatMapStrings applyOne presents
      + injectAdds presents
    );

  # Monolithic fetchCargoVendor vendor: extend its OWN buildCommand (keeps raw's
  # re-pointable vendorStaging that the history rebase reaches into).
  patchInPlace = raw: let
    presents = presentEdits raw;
  in
    if presents == []
    then raw
    else
      raw.overrideAttrs (o: {
        nativeBuildInputs = (o.nativeBuildInputs or []) ++ [hostPkgs.jq hostPkgs.python3];
        buildCommand = (o.buildCommand or "") + applyPlan presents;
      });

  # Granular importCargoLock vendor: mirror the per-crate farm as symlinks so
  # unpatched crates stay shared; applyOne materializes the patched ones. Name
  # kept exact (config.toml points at cargo-vendor-dir).
  patchFarm = raw: let
    presents = presentEdits raw;
  in
    if presents == []
    then raw
    else
      hostPkgs.runCommand (raw.name or "cargo-deps") {
        nativeBuildInputs = [hostPkgs.jq hostPkgs.python3];
      } ''
        mkdir "$out"
        shopt -s dotglob
        for e in ${raw}/*; do ln -s "$e" "$out/$(basename "$e")"; done
        ${applyPlan presents}
      '';

  # buildRustPackage resolves fetchCargoVendor/importCargoLock from the
  # rustPlatform scope, so overrideScope makes it (and wheels, which look up
  # rustPlatform.fetchCargoVendor at call time) produce patched vendors. Must be
  # overrideScope, not a callPackage rebuild of build-rust-package: rebuilding
  # outside makeRustPlatform's splice re-splices cargoSetupHook's `diff` to the
  # wasm target, cross-building diffutils and dragging in a wasm gmp that fails.
  #
  # A package's own vendoring choice is kept: importCargoLock (its per-crate
  # fetchCrate is shared across the rust set) gets patchFarm; fetchCargoVendor's
  # monolithic tree gets patchInPlace. fetchCargoVendor is not converted to the
  # granular importCargoLock form: its deeper per-crate structure overflows nix's
  # default eval stack when the whole python-registry wheel closure is forced.
  #
  # makeOverridable: stock fetchCargoVendor/importCargoLock are callPackage
  # functors (attrsets with __functor), and the cross-splice recurses on that
  # attrset shape. A plain-lambda override is a bare function, so the splice
  # hits `set // function` and dies for any consumer forced through the
  # multi-position splice (jiter, pulled in as a propagated dep). Match the
  # functor shape so the splice stays consistent.
  patchedPlatform = base.overrideScope (final: _: let
    # wasixRebuildVendor: the versioned-history rebase (pkgs/lib/load-packages.nix)
    # calls this to re-vendor a pinned older src (patchInPlace keeps raw's
    # vendorStaging, but the rebase re-runs the wrapper so an older release's
    # layout, such as a lock that moved to src/rust, is handled by re-deciding
    # scoped-vs-full, using the entry's cargoHash).
    attach = drv: rebuild: drv.overrideAttrs (o: {passthru = (o.passthru or {}) // {wasixRebuildVendor = rebuild;};});
  in {
    importCargoLock = lib.makeOverridable (
      args:
        attach (patchFarm (vendorPlatform.importCargoLock args))
        ({src, ...}: patchFarm (vendorPlatform.importCargoLock {lockFileContents = builtins.readFile "${src}/Cargo.lock";}))
    );
    fetchCargoVendor = lib.makeOverridable (
      args: let
        rebuild = {
          src,
          cargoHash ? null,
        }:
          final.fetchCargoVendor (args // {inherit src;} // lib.optionalAttrs (cargoHash != null) {hash = cargoHash;});
      in
        attach (patchInPlace (vendorPlatform.fetchCargoVendor args)) rebuild
    );
  });
in
  base
  // {
    inherit (patchedPlatform) fetchCargoVendor importCargoLock;
    # Expose cargo/rustc at top level so consumers avoid the deprecated rustPlatform.rust.* aliases.
    cargo = cargoWasixCargo;
    rustc = wasixRustToolchain;

    # setuptools-rust wheels propagate these (cc-rs env; source-lock amend);
    # patching is at vendor time.
    inherit wasixDepCcHook wasixLockAmendHook;

    # Re-template maturinBuildHook for the dl target + rust-lld (nixpkgs bakes in
    # wasm32-wasip1, which our toolchain has no std for). Uses nixpkgs' own hook
    # file, not a vendored copy, so it tracks upstream and breaks loudly on a rework.
    maturinBuildHook =
      pkgsCross.makeSetupHook {
        name = "maturin-build-hook.sh";
        propagatedBuildInputs = [
          wasixMaturin
          cargoWasixCargo
          wasixRustToolchain
          exnrefTranslateHook
          wasixDepCcHook
          wasixLockAmendHook
        ];
        substitutions = {
          rustcTargetSpec = "wasm32-wasmer-wasi-dl";
          setEnv = "CARGO_TARGET_WASM32_WASMER_WASI_DL_LINKER=${rustLld}";
        };
      }
      "${pkgsCross.path}/pkgs/build-support/rust/hooks/maturin-build-hook.sh";

    # Wasix defaults layered via lib.extendMkDerivation, NOT a lambda wrapper:
    # base.buildRustPackage is a __functor set whose attrs the cross-splice and
    # .override machinery read; a plain lambda loses them ("expected a set but
    # found a function").
    buildRustPackage = lib.extendMkDerivation {
      constructDrv = patchedPlatform.buildRustPackage;
      extendDrvArgs = finalAttrs: prevArgs: {
        # wasm can't run tests / installChecks on the build host.
        doCheck = false;
        doInstallCheck = false;
        # cargo-auditable would re-link via the host rustc; unneeded for wasm.
        auditable = false;

        nativeBuildInputs = (prevArgs.nativeBuildInputs or []) ++ [wasixDepCcHook wasixLockAmendHook];

        # setEnv points CARGO_TARGET_<wasm>_LINKER at the wasi clang, which can't
        # take rustc's raw wasm-ld flags; override it with the toolchain's rust-lld
        # (the spec's native flavor). Flows through cargoBuildHook to cargo-wasix.
        cargoBuildFlags =
          ["--config" ''target.wasm32-wasmer-wasi.linker="${rustLld}"'']
          ++ (prevArgs.cargoBuildFlags or []);

        # Install each CLI cargo-wasix emitted (<name>.wasm; skip its .wasi/.rustc
        # intermediates).
        installPhase =
          prevArgs.installPhase or ''
            runHook preInstall
            mkdir -p "$out/bin"
            shopt -s nullglob
            for w in target/wasm32-wasmer-wasi/release/*.wasm; do
              case "$w" in *.wasi.wasm | *.rustc.wasm) continue ;; esac
              install -Dm644 "$w" "$out/bin/$(basename "$w")"
            done
            runHook postInstall
          '';

        # Default passthru.wasix.supportedProfiles to the profiles the rust
        # toolchain built std for (a package's own declaration wins). The
        # overlay's applyWasixMeta marks the package unsupported elsewhere;
        # preferredProfileOf derives the shipping profile (eh) from it.
        passthru =
          (prevArgs.passthru or {})
          // {
            wasix =
              {supportedProfiles = wasixRustToolchain.passthru.supportedProfiles;}
              // ((prevArgs.passthru or {}).wasix or {});
          };

        meta = (prevArgs.meta or {}) // {platforms = (prevArgs.meta or {}).platforms or lib.platforms.all;};
      };
    };
  }
