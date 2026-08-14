# Test verdict from two composable markers: expectFail = reason inverts
# pass/fail; broken = reason tolerates an unmet expectation without blocking
# CI. Meeting the expectation while marked hard-fails instead of silently
# succeeding, so a stale marker cannot mask a regression. Callers branch into
# onCheckPass/onCheckFail.
{
  name,
  expectFail ? null,
  broken ? null,
  succeed,
  failHard,
}: let
  expectsFail = expectFail != null;
  isBroken = broken != null;
  tolerateBroken = ''echo "'${name}' failed but is marked broken (${broken}); not blocking CI." >&2; ${succeed}'';
  expectedFailOk = ''echo "'${name}' failed as expected (${expectFail})." >&2; ${succeed}'';
  unexpectedPass = ''echo "'${name}' was expected to fail (${expectFail}) but passed; drop expectFail or check for a coverage regression." >&2; exit 1'';
  staleBroken = ''echo "'${name}' is marked broken (${broken}) but passed; drop the broken marker." >&2; exit 1'';
in {
  onCheckPass =
    if !expectsFail
    then
      if isBroken
      then staleBroken
      else succeed
    else if isBroken
    then tolerateBroken
    else unexpectedPass;
  onCheckFail =
    if expectsFail
    # broken is moot: expectFail's own expectation is already met by failing.
    then expectedFailOk
    else if isBroken
    then tolerateBroken
    else failHard;
}
