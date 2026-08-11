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
in
  pyfinal.buildPythonPackage rec {
    pname = "ddtrace";
    version = "4.13.0";
    pyproject = true;

    src = final.fetchFromGitHub {
      owner = "DataDog";
      repo = "dd-trace-py";
      tag = "v${version}";
      hash = "sha256-iEABtHcmjhdhoV5L30fXeRw3YFWMyNUrcfekyBj57PQ=";
    };

    cargoRoot = "src/native";
    cargoDeps = final.rustPlatform.fetchCargoVendor {
      inherit src;
      name = "${pname}-${version}-cargo-deps";
      sourceRoot = "${src.name}/src/native";
      postPatch = "cp ${./Cargo.lock} Cargo.lock";
      hash = "sha256-V2MLgPNxrYGmzmWw9jTF1nt8nOvgQ3qJx7OkI+kfSh0=";
    };

    # Cargo.lock: upstream's resolves mio 1.2.0, whose wasi backend upstream
    # renamed to wasip1 and gated on target_env = "p1" (not ours), leaving the
    # stub selector that panics the tokio I/O driver at runtime. Ours moves mio
    # to 1.2.2 and tokio to 1.52.3, the versions the wasix backend and Waker
    # crate-patches cover. The committed lock carries no `wasix` crate: the mio
    # fork adds that dep and the patch machinery writes it into the lock (vendor
    # and source alike), so the committed lock stays a plain resolution.
    # library_config: stable-config path consts are OS-gated, their const fns aren't.
    # IAST cmake: prepend the wasm python's headers (build python's fail pyport LONG_BIT).
    # psutil: de-vendored onto ours, which is the same upstream release carrying
    # the wasix port (overlay/python-packages/psutil). Building the vendored copy
    # would mean maintaining that port twice, and its .py side cannot import here
    # at all.
    # build_py: libddwaf is installed below, so skip the artifact wipe
    # ("if False") and the download (no network in the sandbox).
    postPatch = ''
      cp ${./Cargo.lock} src/native/Cargo.lock

      substituteInPlace src/native/library_config.rs \
        --replace-fail 'Configurator::FLEET_STABLE_CONFIGURATION_PATH' 'Configurator::fleet_stable_configuration_path(libdd_library_config::Target::Linux)' \
        --replace-fail 'Configurator::LOCAL_STABLE_CONFIGURATION_PATH' 'Configurator::local_stable_configuration_path(libdd_library_config::Target::Linux)'

      substituteInPlace setup.py \
        --replace-fail 'CURRENT_OS = platform.system()' 'CURRENT_OS = "wasi"' \
        --replace-fail "        if not CustomBuildExt.INCREMENTAL:" "        if False:" \
        --replace-fail "        LibDDWafDownload.run()" "" \
        --replace-fail 'import cmake' "" \
        --replace-fail 'Path(cmake.CMAKE_BIN_DIR) / "cmake"' 'Path(shutil.which("cmake"))' \
        --replace-fail 'f"-DPython3_ROOT_DIR={python_root}",' "" \
        --replace-fail ' + get_exts_for("psutil")' "" \
        --replace-fail "cache=True" "cache=False"

      substituteInPlace pyproject.toml setup.py \
        --replace-fail '"cmake>=3.24.2,<3.28",' "" \
        --replace-fail "\"patchelf>=0.17.0.0; sys_platform == 'linux'\"," ""

      substituteInPlace ddtrace/appsec/_iast/_taint_tracking/CMakeLists.txt \
        --replace-fail 'include_directories(".")' \
        'include_directories(".")
      include_directories(BEFORE SYSTEM "${python}/include/${python.libPrefix}")'

      install -Dm755 ${lib.getLib final.libddwaf}/lib/libddwaf.so \
        ddtrace/appsec/_ddwaf/libddwaf/wasm32/lib/libddwaf.so
      substituteInPlace ddtrace/internal/settings/asm.py \
        --replace-fail '{"Linux": "so", "Darwin": "dylib", "Windows": "dll"}' \
                       '{"Linux": "so", "Darwin": "dylib", "Windows": "dll", "wasi": "so", "wasix": "so"}'

      substituteInPlace ddtrace/internal/runtime/metric_collectors.py \
        --replace-fail '"ddtrace.vendor.psutil"' '"psutil"'
      substituteInPlace ddtrace/internal/settings/profiling.py \
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

    env = {
      SETUPTOOLS_SCM_PRETEND_VERSION = version;
      # tokio's mio Waker is off on wasi; opting in (tokio/1.52.3.patch) needs a
      # mio with the wasix backend, which the lock above pins. Without it the
      # reactor parks with nothing able to wake it and the runtime never drops.
      RUSTFLAGS = "--cfg tokio_wasix_waker";
      DD_COMPILE_ABSEIL = "0"; # abseil is a FetchContent download (IAST map only)
      CIBUILDWHEEL = "1"; # IAST cmake: skip NATIVE_TESTING gtest download
      CMAKE_TOOLCHAIN_FILE = toolchainFile;
    };

    # bumps, then re-derives libddwaf from the new setup.py's LIBDDWAF_VERSION
    # (the nix-update command is passed through as its argv)
    passthru.updateScript =
      ["pkgs/overlay/python-packages/ddtrace/update.py"]
      ++ nix-update-script {extraArgs = ["--flake"];};
    passthru.wasix.updateNotes = [
      {message = "re-hash cargoDeps: nix-update bumps version+src but not a fetchCargoVendor hash spelled inside the package";}
      {message = "regenerate ./Cargo.lock from upstream's src/native lock: keep mio >= 1.2.2 and tokio >= 1.52.3 (the versions the wasix backend and Waker patches cover); the `wasix` crate the mio patch adds is injected at vendor time, so leave it out of the lock; drop the override if upstream resolves such a mio itself";}
      {message = "lib/wasix-crate-patches/libdd-* are now version-independent wasmerAsNative transforms (they narrow libdatadog's browser-wasm cutouts to non-wasmer wasm32) and re-apply to any libdatadog rev automatically; only libdd-common/thread-id.patch (the get_current_thread_id insert) needs a look if upstream restructures threading.rs";}
    ];
  }
