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

  # cargoBuildFlags/cargoTestFlags accept either a list or a shell-word string
  # per the cargoBuildHook interface; normalize to a list before `++`.
  normalizeCargoFlags = argName: flags:
    if builtins.isList flags
    then flags
    else if builtins.isString flags
    then lib.filter (arg: arg != "") (lib.splitString " " flags)
    else throw "wasix rustPlatform: ${argName} must be a list or string";

  # cc-rs (a dependency's build.rs compiling a vendored C library, e.g. ring's
  # BoringSSL) resolves the compiler from CC_<target>, defaulting to the nix cc
  # wrapper, which is stock wasi for the base target and rejects the `-dl`
  # target's PIC-without-EH combination. Wrap wasixcc with the profiles their
  # Rust standard libraries use. The shared exnref hook translates linked .so
  # files afterwards, so the C objects match the Rust ones.
  env = import ../toolchain/env.nix {inherit lib;};
  profiles = (import ../profiles.nix).profiles;
  depBintools = pkgsCross.stdenv.cc.bintools.override {
    libc = null;
    noLibc = true;
    defaultHardeningFlags = [];
  };
  # cc-rs unconditionally passes -fno-exceptions (and -fno-rtti for C++); wasixcc
  # rejects those with PIC, which needs wasm EH (same reason crc32c.nix seds them
  # out of its cmake build). Drop them so WASIXCC_WASM_EXCEPTIONS stands.
  mkDepCc = name: profile: let
    depCcEnv = env.exportsOf (env.profileEnv {
      inherit (profile) wasmExceptions;
      pic = profile.wasmPic or false;
    });
    mkBin = binName: tool:
      pkgsCross.buildPackages.writeShellScriptBin binName ''
        ${depCcEnv}
        args=()
        for a in "$@"; do
          case "$a" in
            -fno-exceptions | -fno-rtti) ;;
            @*)
              responseFile="''${a#@}"
              kept=()
              while IFS= read -r line; do
                case "$line" in
                  -fno-exceptions | -fno-rtti) ;;
                  *) kept+=("$line") ;;
                esac
              done < "$responseFile"
              printf '%s\n' "''${kept[@]}" > "$responseFile"
              args+=("$a")
              ;;
            *) args+=("$a") ;;
          esac
        done
        exec ${lib.getExe' wasixcc tool} "''${args[@]}"
      '';
    shim = pkgsCross.buildPackages.symlinkJoin {
      name = "${name}-unwrapped";
      paths = [
        (mkBin "clang" "wasixcc")
        (mkBin "clang++" "wasix++")
      ];
      passthru.hardeningUnsupportedFlags = ["zerocallusedregs" "stackclashprotection"];
      passthru.isClang = true;
      passthru.isROCm = true;
    };
  in
    pkgsCross.stdenv.cc.override {
      inherit name;
      cc = shim;
      isClang = true;
      libc = null;
      noLibc = true;
      bintools = depBintools;
      libcxx = null;
      extraBuildCommands = "";
      nixSupport = {};
    };
  depCc = mkDepCc "wasix-dep-cc" profiles.eh;
  depCcDl = mkDepCc "wasix-dep-cc-dl" profiles.ehpic;
  depCcPath = lib.getExe' depCc "${depCc.targetPrefix}clang";
  depCxxPath = lib.getExe' depCc "${depCc.targetPrefix}clang++";
  depCcDlPath = lib.getExe' depCcDl "${depCcDl.targetPrefix}clang";
  depCxxDlPath = lib.getExe' depCcDl "${depCcDl.targetPrefix}clang++";
  # cc-rs also reads the dash triple with dashes replaced by underscores, the
  # only form bash can export.
  wasixDepCcHook =
    pkgsCross.makeSetupHook {name = "wasix-dep-cc-hook";}
    (pkgsCross.buildPackages.writeText "wasix-dep-cc-hook.sh" ''
      export CC_wasm32_wasmer_wasi=${depCcPath}
      export CXX_wasm32_wasmer_wasi=${depCxxPath}
      export CC_wasm32_wasmer_wasi_dl=${depCcDlPath}
      export CXX_wasm32_wasmer_wasi_dl=${depCxxDlPath}
    '');

  # `cargo build`/`cargo test` go through cargo-wasix, everything else
  # (metadata, etc.) to the real cargo. Routing `test` gives test binaries the
  # wasm-opt EH->exnref pass before cargo-wasix defers to the runner in
  # CARGO_TARGET_WASM32_WASMER_WASI_RUNNER (our wasix-run). cargo-wasix wants a
  # writable HOME/RUSTUP_HOME for its rustup state.
  cargoWasixCargo = pkgsCross.buildPackages.writeShellScriptBin "cargo" ''
    case "''${1-}" in
      build | test)
        sub=$1
        shift
        export HOME="$PWD/.home"
        export RUSTUP_HOME="$HOME/.rustup"
        mkdir -p "$HOME" "$RUSTUP_HOME"
        exec ${lib.getExe cargoWasix} wasix "$sub" "$@"
        ;;
    esac
    exec ${lib.getExe cargo} "$@"
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

  # Shared with the bootstrap toolchain so every monolithic or granular vendor
  # resolves the same central WASIX crate-edit plan.
  vendorPatches = import ../lib/patch-rust-vendor.nix {
    inherit lib hostPkgs crateEdits;
  };
  inherit (vendorPatches) patchInPlace patchFarm;
  wasixLockAmendHook = vendorPatches.mkLockAmendHook pkgsCross;

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
    # scoped-vs-full, using the entry's cargoHash). A fetchCargoVendor rebuild
    # takes any key besides cargoHash as an override of the original vendor call,
    # which is how a history entry corrects a layout that moved between the two
    # releases; the importCargoLock rebuild re-reads the lock and so honours
    # cargoRoot alone.
    attach = drv: rebuild: drv.overrideAttrs (o: {passthru = (o.passthru or {}) // {wasixRebuildVendor = rebuild;};});
  in {
    importCargoLock = lib.makeOverridable (
      args:
        attach (patchFarm (vendorPlatform.importCargoLock args))
        ({
          src,
          cargoRoot ? null,
          # Upstreams that commit no lock have one supplied by the package file,
          # which selects it per release; there is nothing in src to re-read.
          lockInPackage ? false,
          ...
        }:
          patchFarm (vendorPlatform.importCargoLock (
            if lockInPackage
            then args
            else {
              lockFileContents = builtins.readFile (
                if cargoRoot == null
                then "${src}/Cargo.lock"
                else "${src}/${cargoRoot}/Cargo.lock"
              );
            }
          )))
    );
    fetchCargoVendor = lib.makeOverridable (
      args: let
        # One fixed-output tree: keeping the current release's hash would make nix
        # hand back the vendor already at that path, so a rebased src is only
        # correct with the entry's own hash.
        rebuild = {cargoHash ? null, ...} @ overrides:
          lib.throwIf (cargoHash == null)
          "wasixRebuildVendor: a fetchCargoVendor package needs a cargoHash in its history entry (wasinix versions add <attr>@<version> derives it)"
          (final.fetchCargoVendor (args // builtins.removeAttrs overrides ["cargoHash"] // {hash = cargoHash;}));
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

    # Re-template maturinBuildHook for the dl target + cc-wrapper (nixpkgs bakes in
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
          setEnv = "CARGO_TARGET_WASM32_WASMER_WASI_DL_LINKER=${depCcDlPath}";
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
        # wasm can't run tests on the build host. extendDrvArgs re-runs on
        # overrideAttrs, so read prevArgs rather than forcing false; that is
        # how an emulated check (pkgs/emulated-check.nix) turns doCheck on.
        doCheck = prevArgs.doCheck or false;
        doInstallCheck = prevArgs.doInstallCheck or false;
        # cargo-auditable would re-link via the host rustc; unneeded for wasm.
        auditable = false;

        nativeBuildInputs = (prevArgs.nativeBuildInputs or []) ++ [wasixDepCcHook wasixLockAmendHook];

        # Use the same profile-aware cc-wrapper for Rust and vendored C/C++ so
        # buildInput-derived flags reach every compiler and linker invocation.
        cargoBuildFlags =
          ["--config" ''target.wasm32-wasmer-wasi.linker="${depCcPath}"'']
          ++ normalizeCargoFlags "cargoBuildFlags" (prevArgs.cargoBuildFlags or []);

        # `cargo test` links its own binaries, so it needs the same wrapper.
        cargoTestFlags =
          ["--config" ''target.wasm32-wasmer-wasi.linker="${depCcPath}"'']
          ++ normalizeCargoFlags "cargoTestFlags" (prevArgs.cargoTestFlags or []);

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
