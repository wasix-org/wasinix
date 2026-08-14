# nix uses nlohmann_json for JSON handling.
{
  prev,
  helpers,
  ...
}:
helpers.libTweaks {
  # header-only: ships no static archive to link-smoke.
  passthru.wasix.smokeTest = false;
}
prev.nlohmann_json
