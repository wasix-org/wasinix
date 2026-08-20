# A non-release tree runs `git describe` at import to derive a dev version.
# Its except clause catches OSError, but wasix CPython rejects subprocess `cwd`
# with NotImplementedError, so importing optree raises. We build the tag, which
# is what __release__ marks.
{
  pyprev,
  helpers,
  ...
}:
helpers.extendPackage pyprev.optree {
  postPatch = ''
    substituteInPlace optree/version.py \
      --replace-fail "__release__ = False" "__release__ = True"
  '';
}
