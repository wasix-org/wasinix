# Both installCheckPhase and postFixup run rg through
# `stdenv.hostPlatform.emulator`, whose selection throws at eval time for the
# wasm target (and the man page/completions they generate need to run rg,
# impossible when cross-building). Blank both; the wasix rustPlatform disables
# installChecks anyway. pcre2 (-P) stays on.
{
  exposeWasixPackage,
  extendPackage,
  package,
}:
exposeWasixPackage (
  # No emulatedCheck: the globset --lib suite traps the runtime (exit 27, no
  # Rust panic); a wasmer bug, WASIX-TODO.md.
  extendPackage (package.overrideAttrs (_: {
    postFixup = "";
    installCheckPhase = "";
  })) {
    passthru.wasix.supportedProfiles = ["eh" "ehpic"];
    passthru.wasinix.shipped = true;
  }
)
