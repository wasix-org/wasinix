# wasm32 has no SIMD; libjpeg-turbo's WITH_SIMD default mis-scopes and builds a
# simdcoverage helper that fails to compile. Force it off (C fallback is what
# wasm uses anyway).
{
  prev,
  helpers,
  ...
}:
helpers.libTweaks {
  # libjpeg declares a `man` output but installs no man pages on this target;
  # materialise the dir so the output isn't empty.
  postInstall = ''mkdir -p "$man/share/man"'';
  cmakeFlags = ["-DWITH_SIMD=OFF"];
}
prev.libjpeg
