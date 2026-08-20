# nix uses nlohmann_json for JSON handling.
{
  prev,
  helpers,
  ...
}:
helpers.extendPackage prev.nlohmann_json {
  # header-only: ships no static archive to link-smoke.
  passthru.wasix.smokeTest = false;
}
