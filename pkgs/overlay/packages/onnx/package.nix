# onnx (the C++ core + its python bindings) for wasix. The python onnx wheel is a
# format = "wheel" repackaging of this package's `dist` output.
{
  prev,
  final,
  helpers,
  ...
}: let
  py = final.python3;
  buildPy = py.pythonOnBuildForHost;
in
  helpers.extendPackage prev.onnx {
    # onnx's cross branch creates Python3::Module; nanobind's config wants Python::Module.
    patches = [./patches/onnx-wasi-nanobind-python-module.patch];

    nativeBuildInputs = helpers.python.buildHostPypaBuild buildPy;
    env = {
      # our wasix libprotobuf is a static archive
      ONNX_USE_PROTOBUF_SHARED_LIBS = "0";
      # ONNX's setup.py forwards CMAKE_ARGS through shlex. The stdenv value starts
      # with a space, which becomes a stray -static argument; this override is
      # specific to that setup.py path, not toolchain policy.
      NIX_CFLAGS_LINK = "-static";
    };
    cmakeFlags = [
      "-DPython_INCLUDE_DIR=${py.crossIncludeDir}"
      "-DPython3_INCLUDE_DIR=${py.crossIncludeDir}"
      "-DPython_EXECUTABLE=${buildPy.interpreter}"
    ];
    doCheck = false;
    passthru.wasix.supportedProfiles = helpers.profiles.pic;
  }
