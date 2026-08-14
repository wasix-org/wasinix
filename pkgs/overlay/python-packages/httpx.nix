{
  pyprev,
  pyfinal,
  helpers,
  lib,
  ...
}:
helpers.libTweaks {
  # Omit pytest-trio: Trio dispatches WASIX to its kqueue backend.
  passthru.wasixDeclaredCheckInputs = [pyfinal.pytestCheckHook pyfinal.pytest-asyncio pyfinal.pytest-mock pyfinal.anyio pyfinal.brotlicffi pyfinal.chardet pyfinal.h2 pyfinal.sniffio pyfinal.socksio pyfinal.trustme pyfinal.uvicorn pyfinal.zstandard];
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
pyprev.httpx
