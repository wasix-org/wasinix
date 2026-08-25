# Pytest's default import mode puts the rootdir on sys.path, so the suite
# imports the source tree, not the installed package; importlib mode avoids it.
{
  exposeExtendedPackage,
  packages,
}:
exposeExtendedPackage {
  pytestFlags =
    ["--import-mode=importlib"]
    # asserts python-snappy is absent, but cramjam satisfies snappy; the prefix
    # deselect also covers the _not_installed variants
    ++ ["--deselect" "tests/test_compression.py::test_optional_codecs"];
  # Replaces the stashed check inputs: the inherited numpy is the
  # build-platform one, whose _multiarray_umath the guest cannot load.
  passthru = old:
    old
    // {
      wasixDeclaredCheckInputs = [packages.sameProfile.pytestCheckHook packages.sameProfile.numpy packages.sameProfile.zlib-ng packages.sameProfile.pandas packages.sameProfile.zstandard packages.sameProfile.lz4];
    };
}
