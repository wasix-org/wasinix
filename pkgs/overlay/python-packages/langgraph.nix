# langgraph 1.0 caps langgraph-prebuilt<1.1 and langgraph-sdk<0.4, both of which
# the set has moved past, so a rebased 1.0 takes the history entries instead.
{
  pyprev,
  pyfinal,
  helpers,
  lib,
  ...
}:
helpers.libTweaks (
  lib.optionalAttrs (lib.versionOlder pyprev.langgraph.version "1.1") {
    propagatedBuildInputs = helpers.replaceInputsByName {
      langgraph-prebuilt = pyfinal.langgraph-prebuilt_1_0_8;
      langgraph-sdk = pyfinal.langgraph-sdk_0_3_0;
    };
  }
  // {passthru.wasinix.checks.captured.install = false;}
)
pyprev.langgraph
