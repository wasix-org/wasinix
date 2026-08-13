# nixpkgs strips attrs' hatch plugins with a patch cut against the current
# release, whose hunks miss on a rebased history src. Keep the plugins instead,
# taken from the build host since the cross set's cannot run at build time.
{
  pyprev,
  helpers,
  lib,
  ...
}: let
  buildPy = pyprev.python.pythonOnBuildForHost;
in
  helpers.libTweaks (lib.optionalAttrs ((pyprev.attrs.passthru.wasix.historySpec or null) != null) {
    patches = _: [];
    nativeBuildInputs = [
      buildPy.pkgs.hatch-fancy-pypi-readme
      buildPy.pkgs.hatch-vcs
    ];
  })
  pyprev.attrs
