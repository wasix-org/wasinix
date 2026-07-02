# Both installCheckPhase and postFixup run rg through
# `stdenv.hostPlatform.emulator`, whose selection throws at eval time for the
# wasm target (and the man page/completions they generate need to run rg,
# impossible when cross-building). Blank both; the wasix rustPlatform disables
# installChecks anyway. pcre2 (-P) stays on.
{prev, ...}:
prev.ripgrep.overrideAttrs (_: {
  postFixup = "";
  installCheckPhase = "";
})
