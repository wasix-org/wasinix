# Python build-system glue. Here rather than in the python overrides because
# packages/ builds python consumers too (onnx, onnxruntime's engine).
{
  lib,
  dropInputsByName,
  dropInputsByNameInfix,
}: {
  # nixpkgs puts the target set's pip/wheel/setuptools in nativeBuildInputs, but
  # the wasm ones can't run at build time; swap in buildPython's.
  buildHostPypaTools = buildPython: old:
    dropInputsByName ["pip" "wheel" "setuptools"] old
    ++ [buildPython.pkgs.pip buildPython.pkgs.wheel buildPython.pkgs.setuptools];

  # The same for the pyproject-build frontend and the hook driving it.
  buildHostPypaBuild = buildPython: old:
    dropInputsByNameInfix ["pypa-build-hook"] (dropInputsByName ["build"] old)
    ++ [buildPython.pkgs.build buildPython.pkgs.pypaBuildHook];

  # Strip sphinxHook (+ extraNames, e.g. "myst") and its `doc` output; the docs
  # pass isn't needed and its tools don't cross-build.
  dropSphinxDocs = extraNames: {
    nativeBuildInputs = dropInputsByNameInfix (["sphinx"] ++ extraNames);
    outputs = xs:
      lib.filter (o: o != "doc") (
        if xs == null
        then ["out"]
        else xs
      );
  };
}
