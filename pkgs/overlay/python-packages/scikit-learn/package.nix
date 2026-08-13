# scikit-learn for wasix, built against the cross-built libomp.
{
  pyprev,
  helpers,
  toolchain,
  lib,
  ...
}: let
  isHistory = (pyprev.scikit-learn.passthru.wasix.historySpec or null) != null;
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

    # meson reads the version by running a script the build host cannot, and
    # nixpkgs unbounds three build requirements by matching the current
    # release's literal ranges, which an older release spells differently. The
    # generic [build-system] unbounding in ../default.nix covers the latter, so
    # a rebase keeps only the version substitution.
    postPatch = old:
      if isHistory
      then ''
        sed -i "s|run_command('sklearn/_build_utils/version.py', check: true).stdout().strip(),|'$version',|" meson.build
        grep -q "'$version'," meson.build
      ''
      else old;
  }
  pyprev.scikit-learn
