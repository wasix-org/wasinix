# qrcode 7.x needs typing-extensions and pypng at runtime; 8.0 dropped both, so
# a rebase onto a 7.x src is missing them. buildPythonPackage folds
# `dependencies` into propagatedBuildInputs when it is called, so a later tweak
# has to name the latter.
{
  exposeExtendedPackage,
  packages,
  package,
  lib,
}:
exposeExtendedPackage {
  propagatedBuildInputs = lib.optionals (lib.versionOlder package.version "8") [
    packages.sameProfile.typing-extensions
    packages.sameProfile.pypng
  ];
  # Replaces the stashed check inputs: the inherited pillow is the
  # build-platform one, with no loadable _imaging.
  passthru = old:
    old
    // {
      wasixDeclaredCheckInputs = [packages.sameProfile.pytestCheckHook packages.sameProfile.pillow];
    };
}
