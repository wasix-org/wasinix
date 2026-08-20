# The cv2 bindings. OpenCVDetectPython.cmake probes the runnable build python for
# the header and numpy include dirs, which are 64-bit and corrupt every array on
# wasm32; under CMAKE_CROSSCOMPILING it reads them as cache vars instead.
{
  pyprev,
  wasixPython,
  helpers,
  lib,
  ...
}: let
  py = wasixPython;
  buildPy = py.pythonOnBuildForHost;
  crossNumpyInc = py.pkgs.numpy.crossInclude;
  pyInc = py.crossIncludeDir;
in
  helpers.libTweaks {
    # nixpkgs enables pytest without shipping tests in this wheel. The
    # package-specific cv2 operations check supplies runtime coverage.
    passthru.wasinix.checks.captured.install = false;

    # nixpkgs adds the cross set's pip/wheel/setuptools, which cannot run here.
    nativeBuildInputs = helpers.python.buildHostPypaTools buildPy;

    cmakeFlags = [
      "-DPYTHON3_EXECUTABLE=${buildPy.interpreter}"
      "-DPYTHON3_INCLUDE_PATH=${pyInc}"
      "-DPYTHON3_INCLUDE_DIR=${pyInc}"
      "-DPYTHON3_NUMPY_INCLUDE_DIRS=${crossNumpyInc}"
      "-DOPENCV_PYTHON3_VERSION=${py.pythonVersion}"

      # wasm-ld rejects the -Wl,--exclude-libs=ALL the cv2 link adds.
      "-DOPENCV_PYTHON_SKIP_LINKER_EXCLUDE_LIBS=ON"
    ];

    # libwebp's encoder references SharpYuv* from the split libsharpyuv.a that
    # find_package(WebP) does not propagate; libwebp's -L is already on the link.
    env.NIX_LDFLAGS = "-lsharpyuv";

    # The generated config.py prepends the install lib dir to BINARIES_PATHS,
    # baking a store path a bare wasix pip target cannot resolve into every wheel
    # carrying cv2. That dir holds only static archives here, and the loader uses
    # the list solely to find shared libraries, so it has nothing to contribute.
    postInstall = ''
      echo "BINARIES_PATHS = []" > "$out/${py.sitePackages}/cv2/config.py"
    '';
  }
  pyprev.opencv4
