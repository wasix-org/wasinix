# pandas for wasix. pandas/meson.build takes its numpy include dir from the BUILD
# python, whose NPY_SIZEOF_LONG=8 headers make the cython buffers fail to import
# ("Buffer dtype mismatch") on wasm32.
{
  pyprev,
  wasixPython,
  lib,
  helpers,
  ...
}: let
  crossNumpyInc = wasixPython.pkgs.numpy.crossInclude;
  # 3.0 spells its numpy build pin differently and carries a usable version.
  pre3 = lib.versionOlder pyprev.pandas.version "3";
  # 2.2 pins its build tools exactly; 2.3 relaxed to ranges our set satisfies.
  pinnedBuildTools = lib.versionOlder pyprev.pandas.version "2.3";
in
  helpers.libTweaks {
    # nixpkgs' postPatch --replace-fail's a build pin only 3.x spells that way,
    # so on a 2.x source the miss is fatal and the phase must be replaced.
    postPatch = let
      ours =
        ''
          substituteInPlace pandas/meson.build \
            --replace-fail "incdir = os.path.relpath(np.get_include())" "incdir = os.path.relpath('${crossNumpyInc}')" \
            --replace-fail "incdir = np.get_include()" "incdir = '${crossNumpyInc}'"
        ''
        # src.override re-points the download without nixpkgs' postFetch version
        # sed; generate_version.py prefers an importable _version_meson.
        + lib.optionalString pre3 ''
          printf '__version__ = "%s"\n__git_version__ = "unknown"\n' \
            '${pyprev.pandas.version}' > _version_meson.py
        ''
        + lib.optionalString pinnedBuildTools ''
          substituteInPlace pyproject.toml \
            --replace-fail 'meson-python==0.13.1' 'meson-python' \
            --replace-fail 'meson==1.2.1' 'meson' \
            --replace-fail 'Cython~=3.0.5' 'Cython'
        '';
    in
      if pre3
      then lib.const ours
      else ours;
  }
  pyprev.pandas
