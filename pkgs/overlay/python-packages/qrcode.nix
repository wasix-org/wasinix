# qrcode 7.x needs typing-extensions and pypng at runtime; 8.0 dropped both, so
# a rebase onto a 7.x src is missing them. buildPythonPackage folds
# `dependencies` into propagatedBuildInputs when it is called, so a later tweak
# has to name the latter.
{
  pyprev,
  pyfinal,
  helpers,
  lib,
  ...
}:
helpers.libTweaks {
  propagatedBuildInputs = lib.optionals (lib.versionOlder pyprev.qrcode.version "8") [
    pyfinal.typing-extensions
    pyfinal.pypng
  ];
  # Replaces the stashed check inputs: the inherited pillow is the
  # build-platform one, with no loadable _imaging.
  passthru = old:
    old
    // {
      wasixDeclaredCheckInputs = [pyfinal.pytestCheckHook pyfinal.pillow];
    };
}
pyprev.qrcode
