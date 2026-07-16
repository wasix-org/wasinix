# pandas for wasix. pandas/meson.build takes its numpy include dir from the BUILD python's
# numpy.get_include() → native headers (NPY_SIZEOF_LONG=8) mismatching the wasm numpy (=4),
# so its cython buffers fail to import ("Buffer dtype mismatch"). Point it at the cross numpy.
{
  pyprev,
  wasixPython,
  lib,
  helpers,
  ...
}: let
  wheels = import ./lib/wheels.nix {inherit lib;};
  crossNumpyInc = "${wasixPython.pkgs.numpy}/lib/${wasixPython.libPrefix}/site-packages/numpy/_core/include";
in
  # wasm build only: a native pandas must keep its own np.get_include().
  wheels.onlyOnWasix pyprev.pandas (
    helpers.libTweaks {
      postPatch = ''
        substituteInPlace pandas/meson.build \
          --replace-fail "incdir = os.path.relpath(np.get_include())" "incdir = os.path.relpath('${crossNumpyInc}')" \
          --replace-fail "incdir = np.get_include()" "incdir = '${crossNumpyInc}'"
      '';
    }
    pyprev.pandas
  )
