# pypandoc-binary for wasix (not a separate nixpkgs attr): upstream builds it
# from the same source via setup_binary.py, packaging a real pandoc at
# pypandoc/files/pandoc (__init__ searches that dir before PATH). Bundle the
# overlay's wasm pandoc so `pip install pypandoc_binary` works without the
# pandoc webc. poetry's pyproject.toml describes only the plain variant; drop
# it so setuptools builds from setup(_binary).py.
{
  pyfinal,
  preferredProfilePackages,
  helpers,
  ...
}:
helpers.libTweaks {
  pname = "pypandoc-binary";
  nativeBuildInputs = [pyfinal.setuptools pyfinal.wheel];
  postPatch = ''
    mv setup_binary.py setup.py
    rm pyproject.toml
    # setup_requires wants pip, which is never used in-build (and does not
    # cross-build); drop the check.
    substituteInPlace setup.py \
      --replace-fail "setup_requires=pypandoc.__setup_requires__," ""
    install -Dm755 ${preferredProfilePackages.pandoc}/bin/pandoc.wasm pypandoc/files/pandoc
  '';
}
pyfinal.pypandoc
