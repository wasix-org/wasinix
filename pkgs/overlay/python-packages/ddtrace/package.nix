# ddtrace for wasix (not in nixpkgs). CURRENT_OS="wasi" gates off
# ddup/stack_v2/crashtracker/profiling; keeps cython/C exts, IAST cmake,
# psutil, and the rust _native exporter. libddwaf bundled (no wasm release).
{
  final,
  pyfinal,
  lib,
  ...
}: let
  python = final.python3;
  # setup.py runs cmake itself; cross facts go in via CMAKE_TOOLCHAIN_FILE.
  toolchainFile = final.buildPackages.writeText "ddtrace-wasi-toolchain.cmake" ''
    set(CMAKE_SYSTEM_NAME WASI)
    set(CMAKE_SYSTEM_VERSION 1)
    set(CMAKE_SYSTEM_PROCESSOR wasm32)
    set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
    set(Python_INCLUDE_DIR ${python}/include/${python.libPrefix})
    set(Python3_INCLUDE_DIR ${python}/include/${python.libPrefix})
    set(PYTHON_MODULE_EXTENSION ".so")
  '';
in
  pyfinal.buildPythonPackage rec {
    pname = "ddtrace";
    version = "3.19.8";
    pyproject = true;

    src = final.fetchFromGitHub {
      owner = "DataDog";
      repo = "dd-trace-py";
      tag = "v${version}";
      hash = "sha256-N+Q4yx9iMmMW6wkXhaN/3A6Is9Bll2jnH4Pe/rV/uIU=";
    };

    cargoRoot = "src/native";
    cargoDeps = final.rustPlatform.fetchCargoVendor {
      inherit src;
      name = "${pname}-${version}-cargo-deps";
      sourceRoot = "${src.name}/src/native";
      postPatch = "cp ${./Cargo.lock} Cargo.lock";
      hash = "sha256-uyFDdJgz4UDPpWW4II235crMHmbmgWya86X1BzayNyc=";
    };

    patches = [./patches/vendored-psutil-wasi.patch];

    # library_config: stable-config path consts are OS-gated, their const fns aren't.
    # IAST cmake: prepend the wasm python's headers (build python's fail pyport LONG_BIT).
    postPatch = ''
      cp ${./Cargo.lock} src/native/Cargo.lock

      substituteInPlace src/native/library_config.rs \
        --replace-fail 'Configurator::FLEET_STABLE_CONFIGURATION_PATH' 'Configurator::fleet_stable_configuration_path(libdd_library_config::Target::Linux)' \
        --replace-fail 'Configurator::LOCAL_STABLE_CONFIGURATION_PATH' 'Configurator::local_stable_configuration_path(libdd_library_config::Target::Linux)'

      substituteInPlace setup.py \
        --replace-fail 'CURRENT_OS = platform.system()' 'CURRENT_OS = "wasi"' \
        --replace-fail "        CleanLibraries.remove_artifacts()" "" \
        --replace-fail "        LibDDWafDownload.run()" "" \
        --replace-fail 'import cmake' "" \
        --replace-fail '"cmake>=3.24.2,<3.28", ' "" \
        --replace-fail 'Path(cmake.CMAKE_BIN_DIR) / "cmake"' 'Path(shutil.which("cmake"))' \
        --replace-fail 'f"-DPython3_ROOT_DIR={sys.prefix}",' "" \
        --replace-fail "cache=True" "cache=False"

      substituteInPlace pyproject.toml \
        --replace-fail "    \"cmake>=3.24.2,<3.28; python_version>='3.8'\"," "" \
        --replace-fail "    \"patchelf>=0.17.0.0; sys_platform == 'linux'\"," ""

      substituteInPlace pyproject.toml setup.py \
        --replace-fail 'setuptools_scm[toml]>=4,<10' 'setuptools_scm[toml]>=4'

      substituteInPlace ddtrace/appsec/_iast/_taint_tracking/CMakeLists.txt \
        --replace-fail 'include_directories(".")' \
        'include_directories(".")
      include_directories(BEFORE SYSTEM "${python}/include/${python.libPrefix}")'

      install -Dm755 ${lib.getLib final.libddwaf}/lib/libddwaf.so \
        ddtrace/appsec/_ddwaf/libddwaf/wasm32/lib/libddwaf.so
      substituteInPlace ddtrace/settings/asm.py \
        --replace-fail '{"Linux": "so", "Darwin": "dylib", "Windows": "dll"}' \
                       '{"Linux": "so", "Darwin": "dylib", "Windows": "dll", "wasi": "so", "wasix": "so"}'
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
      wrapt
    ];

    env = {
      SETUPTOOLS_SCM_PRETEND_VERSION = version;
      DD_COMPILE_ABSEIL = "0"; # abseil is a FetchContent download (IAST map only)
      CIBUILDWHEEL = "1"; # IAST cmake: skip NATIVE_TESTING gtest download
      CMAKE_TOOLCHAIN_FILE = toolchainFile;
    };

    passthru.wasix.updateNotes = [
      {message = "regenerate ./Cargo.lock (upstream's src/native lock omits datadog-ffe and lacks the mio/socket2 wasix-crate-patch deps); drop the override if upstream's lock is consistent";}
    ];
  }
