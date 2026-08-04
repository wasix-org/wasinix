# onnx wheel for wasix: `format = "wheel"` over the C++ onnx's abi3 dist. Point it at
# the default-python `final.onnx` instead of the interpreter-local one: the extension
# is limited-API (Py_LIMITED_API 0x030C0000), so its wheel is tagged cp312-abi3 and one
# file is the correct answer for every interpreter. The worklist publishes the default
# wrapper's artifact once while retaining both wrappers for tests and dependency closure.
{
  pyprev,
  final,
  helpers,
  ...
}:
helpers.libTweaks {
  # pythonRuntimeDepsCheckHook imports `packaging` on the build host.
  dontCheckRuntimeDeps = true;
  # Upstream keeps the C++ onnx as a buildInput to hold the module's RUNPATH, which the
  # wasm module has no use for; here it would put the default python set on PYTHONPATH.
  buildInputs = helpers.dropInputsByName ["onnx"];
  propagatedBuildInputs = helpers.dropInputsByName ["onnx"];
}
(pyprev.onnx.override {onnx = final.onnx;})
