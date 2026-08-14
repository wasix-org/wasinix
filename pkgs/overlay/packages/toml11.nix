# nix uses toml11 for TOML parsing.
{
  prev,
  helpers,
  ...
}:
helpers.libTweaks {
  # header-only: ships no static archive to link-smoke.
  passthru.wasix.smokeTest = false;
}
prev.toml11
