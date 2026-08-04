# scikit-learn for wasix, built against the cross-built libomp.
{
  pyprev,
  helpers,
  toolchain,
  ...
}: let
  # openblas has no wasm build (scikit-learn reaches BLAS through scipy's cython
  # .pxd); nixpkgs' openmp needs an llvm-static that does not cross-build.
  dropUnwanted = xs:
    helpers.dropInputsByNameInfix ["openmp-static"]
    (helpers.dropInputsByName ["openblas" "blas" "lapack" "openmp"] xs);
in
  helpers.libTweaks {
    # The cross python mirrors buildInputs into propagatedBuildInputs.
    buildInputs = old: dropUnwanted old ++ [toolchain.openmp];
    propagatedBuildInputs = dropUnwanted;
  }
  pyprev.scikit-learn
