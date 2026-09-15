# No suite: the tests spawn the claude CLI and sys.executable, and an in-guest
# exec of a shebanged wasm re-enters the wasix-run stub (WASIX-TODO.md).
{exposeExtendedPackage}:
exposeExtendedPackage {
  passthru.wasinix.checks.captured.install = false;
  # PyPI ships only platform-tagged wheels (macosx/manylinux/win, no
  # py3-none-any), none installable on wasix, so the registry serves our pure
  # build.
  passthru.wasinix.publication.supersedesPyPI = true;
}
