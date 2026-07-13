# Upstream forces -fno-exceptions, which wasixcc deduces into an off-ABI
# artifact whatever the profile. Strip it; the profile decides.
{
  prev,
  helpers,
  ...
}:
helpers.libTweaks {
  postPatch = ''
    substituteInPlace CMakeLists.txt \
      --replace-fail ' -fno-exceptions"' '"'
  '';
}
prev.snappy
