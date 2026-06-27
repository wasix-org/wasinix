# ripgrep (rg) — a fast recursive grep in Rust. Both installCheckPhase and postFixup run rg
# through `stdenv.hostPlatform.emulator`, whose selection throws for the wasm target at eval
# time (and the man page + shell completions they generate need to *run* rg, impossible when
# cross-building). Blank both; the seam disables installChecks anyway. pcre2 (-P) stays on.
{prev, ...}:
prev.ripgrep.overrideAttrs (_: {
  postFixup = "";
  installCheckPhase = "";
})
