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
    version = "4.11.1";
    pyproject = true;

    src = final.fetchFromGitHub {
      owner = "DataDog";
      repo = "dd-trace-py";
      tag = "v${version}";
      hash = "sha256-MKZaf+Y5Y9xpkYrLHA0RMxB62EMuUK1mvTBdf0zpN1s=";
    };

    cargoRoot = "src/native";
    cargoDeps = final.rustPlatform.fetchCargoVendor {
      inherit src;
      name = "${pname}-${version}-cargo-deps";
      sourceRoot = "${src.name}/src/native";
      postPatch = "cp ${./Cargo.lock} Cargo.lock";
      hash = "sha256-5D/FJpVz9KaTZaPg3OMGQU28nH6qXUoOC37epy9C0vA=";
    };

    # Cargo.lock: upstream's resolves mio 1.2.0, whose wasi backend upstream
    # renamed to wasip1 and gated on target_env = "p1" (not ours), leaving the
    # stub selector that panics the tokio I/O driver at runtime. Ours moves mio
    # to 1.2.2 and tokio to 1.52.3, the versions the wasix backend and Waker
    # crate-patches cover, and carries the `wasix` dep the mio patch adds.
    # library_config: stable-config path consts are OS-gated, their const fns aren't.
    # IAST cmake: prepend the wasm python's headers (build python's fail pyport LONG_BIT).
    # psutil exts: not built, vendored psutil/__init__.py raises on sys.platform
    # "wasix", so they could never be imported (and their linux/ uapi headers,
    # sched_*affinity and sysinfo() are all absent from the sysroot).
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
      {message = "regenerate ./Cargo.lock from upstream's src/native lock: keep mio >= 1.2.2 and tokio >= 1.52.3 (the versions the wasix backend and Waker patches cover) and keep the `wasix` dep the mio patch adds; drop the override if upstream resolves such a mio itself";}
      {message = "regenerate lib/wasix-crate-patches/libdd-* if the libdatadog rev moved: they narrow libdatadog's browser-wasm cutouts to non-wasmer wasm32 (see WASIX-TODO.md), mechanically, and are keyed by libdatadog's own crate versions";}
    ];
  }
