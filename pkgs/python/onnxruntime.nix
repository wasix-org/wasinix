# onnxruntime wheel for wasix. The pybind11 module is per-interpreter, so the C++
# engine is rebuilt with pythonSupport against this set's python and its dist
# repackaged, once per interpreter.
{
  pyprev,
  final,
  wasixPython,
  helpers,
  ...
}: let
  py = wasixPython;
  buildPy = py.pythonOnBuildForHost;
  crossNumpyInc = py.pkgs.numpy.crossInclude;
  pyInc = py.crossIncludeDir;

  # x86 RUNPATH-fixup libs with no wasm build; the module links the engine statically.
  dropInputs = ["onednn" "re2" "openvino"];
  dropByName = helpers.dropInputsByName dropInputs;

  engine =
    (final.onnxruntime.override {
      pythonSupport = true;
      python3Packages = py.pkgs;
    })
    .overrideAttrs (o: {
      # nixpkgs puts the cross set's pip/setuptools/wheel here, which cannot run.
      nativeBuildInputs = helpers.python.buildHostPypaTools buildPy o.nativeBuildInputs;
      cmakeFlags =
        (o.cmakeFlags or [])
        ++ [
          # find_package(Python) runs this one but compiles against wasm headers.
          "-DPython_EXECUTABLE=${buildPy.interpreter}"
          "-DPython3_EXECUTABLE=${buildPy.interpreter}"
          "-DPython_INCLUDE_DIR=${pyInc}"
          "-DPython3_INCLUDE_DIR=${pyInc}"
          # The singular, absolute form seeds FindPython's cache and skips the
          # interpreter probe, which would return 64-bit npy_intp headers.
          "-DPython_NumPy_INCLUDE_DIR=${crossNumpyInc}"
          "-DPython3_NumPy_INCLUDE_DIR=${crossNumpyInc}"
        ];
      postBuild = "${buildPy.interpreter} ../setup.py bdist_wheel";
    });
in
  helpers.extendPackage (pyprev.onnxruntime.override {onnxruntime = engine;}) {
    # nixpkgs enables pytest without shipping tests in the installed wheel.
    # The package-specific inference check below provides runtime coverage.
    passthru.wasinix.checks.captured.install = false;
    # pythonRuntimeDepsCheckHook imports `packaging` on the build host.
    dontCheckRuntimeDeps = true;
    buildInputs = dropByName;
    propagatedBuildInputs = dropByName;
  }
