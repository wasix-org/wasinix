# pyzmq for wasix (scikit-build-core). The patch teaches pyzmq's auto-detect to
# accept the static libzmq target from wasix/zeromq.nix; without
# Python_INCLUDE_DIR, find_package(Python) picks the build interpreter's headers.
{
  exposeExtendedPackage,
  packages,
  pkgs,
}: let
  py = packages.sameProfile.python;
in
  exposeExtendedPackage {
    patches = [./patches/pyzmq-detect-static-libzmq.patch];
    cmakeFlags = [
      "-DPython_INCLUDE_DIR=${py.crossIncludeDir}"
      "-DPython_EXECUTABLE=${py.pythonOnBuildForHost.interpreter}"
      # under CMP0190 FindPython refuses Interpreter + Development.Module together
      # when cross-compiling unless an emulator is set; `env` is the identity one.
      "-DCMAKE_CROSSCOMPILING_EMULATOR=${pkgs.lib.getExe' pkgs.buildPackages.coreutils "env"}"
    ];
    # libzmq.a is C++ but the extension links with the C driver.
    env.NIX_LDFLAGS = "-lc++ -lc++abi -lunwind";
    # The async socket suite blocks immediately under Wasmer. The import
    # import check still exercises the extension and bundled libzmq.
    passthru.wasinix.checks.captured.install = false;
  }
