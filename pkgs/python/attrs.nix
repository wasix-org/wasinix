# nixpkgs strips attrs' hatch plugins with a patch cut against the current
# release, whose hunks miss on a rebased history src. Keep the plugins instead,
# taken from the build host since the cross set's cannot run at build time.
{
  exposeExtendedPackage,
  packages,
  package,
  lib,
}: let
  buildPy = packages.sameProfile.python.pythonOnBuildForHost;
in
  exposeExtendedPackage (
    lib.optionalAttrs ((package.passthru.wasix.historySpec or null) != null) {
      patches = _: [];
      nativeBuildInputs = [
        buildPy.pkgs.hatch-fancy-pypi-readme
        buildPy.pkgs.hatch-vcs
      ];
    }
    // {
      passthru = old:
        old
        // {
          wasinix = (old.wasinix or {}) // {checks.captured.install = true;};
          wasixDeclaredCheckInputs = [packages.sameProfile.pytestCheckHook packages.sameProfile.hypothesis packages.sameProfile.pretend];
        };
      pytestFlags = ["--import-mode=importlib"];
      disabledTests = ["test_overwrite_base"];
    }
  )
