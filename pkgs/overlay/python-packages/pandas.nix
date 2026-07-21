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
  # 3.0 spells its numpy build pin differently and carries a usable version;
  # everything below needs both corrected.
  pre3 = lib.versionOlder pyprev.pandas.version "3";
  # 2.2 pins its build tools exactly (meson==1.2.1, Cython~=3.0.5); 2.3 already
  # relaxed to ranges our set satisfies. Relax the exact pins to ours.
  pinnedBuildTools = lib.versionOlder pyprev.pandas.version "2.3";
in
  # wasm build only: a native pandas must keep its own np.get_include().
  wheels.onlyOnWasix pyprev.pandas (
    helpers.libTweaks {
      # lib.const on <3: nixpkgs' postPatch relaxes a "numpy>=2.0.0" build pin
      # that only 3.x spells that way, with --replace-fail, so on a 2.x source
      # the miss is fatal. Replace the phase rather than appending to it.
      postPatch = let
        ours =
          ''
            substituteInPlace pandas/meson.build \
              --replace-fail "incdir = os.path.relpath(np.get_include())" "incdir = os.path.relpath('${crossNumpyInc}')" \
              --replace-fail "incdir = np.get_include()" "incdir = '${crossNumpyInc}'"
          ''
          + lib.optionalString pre3 ''
            # nixpkgs' src postFetch seds ITS OWN version into _version.py's
            # git_refnames, and src.override re-points the download without
            # re-running it, so a rebased tarball arrives stamped with the
            # current version and versioneer reports that. generate_version.py
            # prefers an importable _version_meson over versioneer, so state the
            # version here instead of depending on that sed.
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
  )
