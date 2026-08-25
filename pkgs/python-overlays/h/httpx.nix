{
  exposeExtendedPackage,
  packages,
  lib,
}:
exposeExtendedPackage {
  # Omit pytest-trio: Trio dispatches WASIX to its kqueue backend.
  passthru.wasixDeclaredCheckInputs = [packages.sameProfile.pytestCheckHook packages.sameProfile.pytest-asyncio packages.sameProfile.pytest-mock packages.sameProfile.anyio packages.sameProfile.brotlicffi packages.sameProfile.chardet packages.sameProfile.h2 packages.sameProfile.sniffio packages.sameProfile.socksio packages.sameProfile.trustme packages.sameProfile.uvicorn packages.sameProfile.zstandard];
  postPatch = ''
    substituteInPlace pyproject.toml \
      --replace-fail '  "ignore: trio.MultiError is deprecated since Trio 0.22.0:trio.TrioDeprecationWarning"' \
                     ""
    substituteInPlace tests/concurrency.py \
      --replace-fail 'import trio' '# Trio cases are disabled on WASIX.'
  '';
  pytestFlags = old: lib.filter (flag: flag != "-Wignore::trio.TrioDeprecationWarning") old;
  disabledTests = ["trio"];
}
