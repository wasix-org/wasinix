{
  stdenvNoCC,
  rustPlatform,
  fetchFromGitHub,
  bash,
  wasixLlvm,
  binaryen,
  wasixSysroot,
  stdenv,
}: let
  src = fetchFromGitHub {
    owner = "wasix-org";
    repo = "wasixcc";
    rev = "f60fd7d03690fc778633b3616caee39015fb8404";
    hash = "sha256-opTdoRjWIsNDCce2XaUdmn9RwzpesqXusw5QHp5Q8FE=";
  };

  cargoToml = builtins.fromTOML (builtins.readFile "${src}/Cargo.toml");
  version = cargoToml.package.version;

  supported = stdenv.hostPlatform.isLinux && stdenv.hostPlatform.isx86_64;

  wasixccRaw = rustPlatform.buildRustPackage {
    pname = "wasixcc-raw";
    inherit version src;
    cargoLock.lockFile = "${src}/Cargo.lock";

    patches = [
      ./wasixcc-discard-undefined-version.patch
      # wasixcc's no-input passthrough runs clang without pinning the linker, so
      # clang-driven linker probes (meson's `cc -Wl,--version`) fail to find a bare
      # `wasm-ld` off PATH. Pin it. TODO: upstream to wasix-org/wasixcc.
      ./wasixcc-pin-linker-in-passthrough.patch
      # wasixcc only links the C++ runtime (-lc++/-lc++abi) into executables, not
      # shared libraries — so a C++ CPython extension's .so leaves its libc++ symbols
      # as unresolved dynamic imports that the C interpreter can't satisfy at load.
      # Link the C++ runtime into C++ shared libs too. TODO: upstream.
      ./wasixcc-link-cxx-runtime-into-shared-libs.patch
    ];

    doCheck = true;

    installPhase = ''
      runHook preInstall
      mkdir -p "$out/libexec"
      cp "$(find target -type f -path '*/release/wasixccenv' | head -n 1)" "$out/libexec/wasixccenv"
      runHook postInstall
    '';
  };
in
  if supported
  then
    stdenvNoCC.mkDerivation {
      pname = "wasixcc";
      inherit version;
      dontUnpack = true;

      # Update instructions:
      # 1) Update `src.rev` and `src.hash` to the target wasix-org/wasixcc commit.
      # 2) If Cargo dependencies changed, the updated Cargo.lock (cargoLock.lockFile above,
      #    from the pinned src) is picked up automatically — no hash to bump; just rebuild.
      # 3) Keep wrapper env vars aligned with pkgs/default.nix toolchain env exports.
      installPhase = ''
        runHook preInstall
        mkdir -p "$out/bin" "$out/libexec"

        cp "${wasixccRaw}/libexec/wasixccenv" "$out/libexec/wasixccenv"

        for cmd in wasixcc 'wasix++' wasixcc++ wasixar wasixnm wasixranlib wasixld wasixccenv; do
          printf '%s\n' \
            '#!${bash}/bin/bash' \
            'set -euo pipefail' \
            'export WASIXCC_LLVM_LOCATION="${wasixLlvm}"' \
            'export WASIXCC_BINARYEN_LOCATION="${binaryen}"' \
            'export WASIXCC_SYSROOT_PREFIX="${wasixSysroot}"' \
            "exec -a \"\$0\" \"$out/libexec/wasixccenv\" \"\$@\"" \
            > "$out/bin/$cmd"
          chmod +x "$out/bin/$cmd"
        done

        runHook postInstall
      '';
    }
  else throw "wasixcc package currently supports only x86_64-linux; current system is ${stdenv.hostPlatform.system}"
