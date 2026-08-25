# langgraph 1.0 caps langgraph-prebuilt<1.1 and langgraph-sdk<0.4, both of which
# the set has moved past, so a rebased 1.0 takes the history entries instead.
{
  exposeExtendedPackage,
  packages,
  package,
  lib,
  replaceInputsByName,
}:
exposeExtendedPackage (
  lib.optionalAttrs (lib.versionOlder package.version "1.1") {
    propagatedBuildInputs = replaceInputsByName {
      langgraph-prebuilt = packages.sameProfile.langgraph-prebuilt.versions."1.0.8";
      langgraph-sdk = packages.sameProfile.langgraph-sdk.versions."0.3.0";
    };
  }
  // {passthru.wasinix.checks.captured.install = false;}
)
