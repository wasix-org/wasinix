# ddtrace for wasix (not in nixpkgs). CURRENT_OS="wasi" gates off
# ddup/stack_v2/crashtracker/profiling; keeps cython/C exts, IAST cmake and the
# rust _native exporter. libddwaf bundled (no wasm release).
{
  final,
  pyfinal,
  lib,
  nix-update-script,
  ...
}: let
  # the wheel's own interpreter, not final.python3: this package is built once
  # per interpreter and the IAST extension links against these headers.
  python = pyfinal.python;
  # setup.py runs cmake itself; cross facts go in via CMAKE_TOOLCHAIN_FILE.
  # pybind11 3.x skips its host/target checks only when told to cross-compile.
  toolchainFile = final.buildPackages.writeText "ddtrace-wasi-toolchain.cmake" ''
    set(CMAKE_SYSTEM_NAME WASI)
    set(CMAKE_SYSTEM_VERSION 1)
    set(CMAKE_SYSTEM_PROCESSOR wasm32)
    set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
    set(Python_INCLUDE_DIR ${python}/include/${python.libPrefix})
    set(Python3_INCLUDE_DIR ${python}/include/${python.libPrefix})
    set(PYTHON_MODULE_EXTENSION ".so")
    set(PYBIND11_USE_CROSSCOMPILING ON CACHE BOOL "" FORCE)
  '';
  updateWrapper = final.buildPackages.writeShellApplication {
    name = "ddtrace-update";
    runtimeInputs = with final.buildPackages; [
      curl
      git
      gnugrep
      gnused
      jq
    ];
    text = ''
      exec bash "$(git rev-parse --show-toplevel)/pkgs/overlay/python-packages/ddtrace/update.sh" "$@"
    '';
  };
in
  pyfinal.buildPythonPackage (finalAttrs: {
    pname = "ddtrace";
    version = "4.13.1";
    pyproject = true;

    src = final.fetchFromGitHub {
      owner = "DataDog";
      repo = "dd-trace-py";
      tag = "v${finalAttrs.version}";
      hash = "sha256-ffqJADnc+PRCRGNYXjUlEMX15Bzxd4HzdyFGIcaZgMw=";
    };

    cargoRoot = "src/native";
    cargoDeps = final.rustPlatform.fetchCargoVendor {
      inherit (finalAttrs) src;
      name = "${finalAttrs.pname}-${finalAttrs.version}-cargo-deps";
      sourceRoot = "${finalAttrs.src.name}/src/native";
      hash = "sha256-/R6AyuNQEQVo0hPMfieTU+7RUlpcuwvZlPU7JyuM3SI=";
    };

    # locks/: a release whose own lock does not resolve its manifest vendors from
    # one generated here, named for the release, which its history entry vendors
    # from too. The rebase reaches this file with the version only in the build
    # environment (pkgs/lib/load-packages.nix).
    # settings/: 4.x moved the package under ddtrace/internal.
    # cmake and patchelf: build requirements we satisfy from nixpkgs, spelled
    # with an environment marker in one release and bare in another, and listed
    # in only one of the two files below 4.x.
    # library_config: stable-config path consts are OS-gated, their const fns aren't.
    # IAST cmake: prepend the wasm python's headers (build python's fail pyport LONG_BIT).
    # psutil: de-vendored onto ours, which is the same upstream release carrying
    # the wasix port (overlay/python-packages/psutil). Building the vendored copy
    # would mean maintaining that port twice, and its .py side cannot import here
    # at all.
    # build_py: libddwaf is installed below, so skip the artifact wipe and the
    # download (no network in the sandbox). 4.x guards the wipe on an INCREMENTAL
    # flag and 3.x calls it outright, so neuter the call the download follows,
    # which leaves the guard in place and the clean command untouched.
    postPatch = ''
      if [ -f ${./locks}/$version.lock ]; then
        cp ${./locks}/$version.lock src/native/Cargo.lock
      fi

      substituteInPlace src/native/library_config.rs \
        --replace-fail 'Configurator::FLEET_STABLE_CONFIGURATION_PATH' 'Configurator::fleet_stable_configuration_path(libdd_library_config::Target::Linux)' \
        --replace-fail 'Configurator::LOCAL_STABLE_CONFIGURATION_PATH' 'Configurator::local_stable_configuration_path(libdd_library_config::Target::Linux)'

      substituteInPlace setup.py \
        --replace-fail 'CURRENT_OS = platform.system()' 'CURRENT_OS = "wasi"' \
        --replace-fail 'import cmake' "" \
        --replace-fail 'Path(cmake.CMAKE_BIN_DIR) / "cmake"' 'Path(shutil.which("cmake"))' \
        --replace-fail ' + get_exts_for("psutil")' "" \
        --replace-fail "cache=True" "cache=False"

      sed -i -E 's/"(cmake|patchelf)>=[^"]*", ?//' pyproject.toml setup.py
      ! grep -qE '"(cmake|patchelf)>=' pyproject.toml setup.py

      grep -q "DPython3_ROOT_DIR" setup.py
      sed -i -E '/^ +f"-DPython3_ROOT_DIR=/d' setup.py

      sed -i -E '/^ +LibDDWafDownload\.run\(\)$/d' setup.py
      sed -i -E '/^ +CleanLibraries\.remove_artifacts\(\)$/{N;s/^( +)CleanLibraries\.remove_artifacts\(\)\n( +BuildPyCommand\.run\(self\))$/\1pass\n\2/}' setup.py
      grep -q "^ \+pass$" setup.py

      substituteInPlace ddtrace/appsec/_iast/_taint_tracking/CMakeLists.txt \
        --replace-fail 'include_directories(".")' \
        'include_directories(".")
      include_directories(BEFORE SYSTEM "${python}/include/${python.libPrefix}")'

      install -Dm755 ${lib.getLib final.libddwaf}/lib/libddwaf.so \
        ddtrace/appsec/_ddwaf/libddwaf/wasm32/lib/libddwaf.so
      settings=ddtrace/internal/settings
      [ -d $settings ] || settings=ddtrace/settings
      substituteInPlace $settings/asm.py \
        --replace-fail '{"Linux": "so", "Darwin": "dylib", "Windows": "dll"}' \
                       '{"Linux": "so", "Darwin": "dylib", "Windows": "dll", "wasi": "so", "wasix": "so"}'

      substituteInPlace ddtrace/internal/runtime/metric_collectors.py \
        --replace-fail '"ddtrace.vendor.psutil"' '"psutil"'
      substituteInPlace $settings/profiling.py \
        --replace-fail 'from ddtrace.vendor import psutil' 'import psutil'
      substituteInPlace pyproject.toml \
        --replace-fail '    "envier~=0.6.1",' '    "envier~=0.6.1",
      "psutil",'
      rm -r ddtrace/vendor/psutil
    '';

    build-system = with pyfinal; [
      setuptools
      setuptools-scm
      cython
      setuptools-rust
    ];

    # hand-written pkg (no callPackage splice): reach the build-host
    # cargoSetupHook explicitly, else final.rustPlatform's wasm-cross one pulls
    # wasm coreutils. cargo/rustc: setup.py probes for a rust toolchain before
    # reporting build requires. crate-patch + dep-cc hooks come via setuptools-rust.
    nativeBuildInputs = [
      final.buildPackages.rustPlatform.cargoSetupHook
      final.buildPackages.cmake
      final.rustPlatform.cargo
      final.rustPlatform.rustc
    ];
    dontUseCmakeConfigure = true;

    dependencies = with pyfinal; [
      bytecode
      envier
      opentelemetry-api
      psutil
      wrapt
    ];

    # setuptools-scm has no git tree to read here. Exported from the build
    # environment rather than set in `env`, where a rebased build could leave
    # its METADATA version out of sync with the derivation.
    preBuild = ''
      export SETUPTOOLS_SCM_PRETEND_VERSION="$version"
    '';

    env = {
      # tokio's mio Waker is off on wasi; opting in (tokio/1.51.0.patch) needs
      # mio's wasix backend from the crate patches. Without it the reactor parks
      # with nothing able to wake it and the runtime never drops.
      RUSTFLAGS = "--cfg tokio_wasix_waker";
      DD_COMPILE_ABSEIL = "0"; # abseil is a FetchContent download (IAST map only)
      CIBUILDWHEEL = "1"; # IAST cmake: skip NATIVE_TESTING gtest download
      CMAKE_TOOLCHAIN_FILE = toolchainFile;
    };

    # bumps, then re-derives libddwaf from the new setup.py's LIBDDWAF_VERSION
    # (the nix-update command is passed through as its argv)
    passthru.updateScript = {
      command =
        [
          lib.getExe
          updateWrapper
        ]
        ++ nix-update-script {extraArgs = ["--flake"];};
      accepts = [
        "release"
        "revision"
      ];
      source = {
        kind = "github";
        owner = "DataDog";
        repo = "dd-trace-py";
      };
    };
  })
