# pytz for wasix. pytz bundles ${tzdata}/share/zoneinfo, but the cross tzdata doesn't build
# (zic uses getresuid etc.). zoneinfo is platform-independent, so use the build-platform tzdata.
{
  pyfinal,
  pyprev,
  final,
  helpers,
  ...
}:
helpers.extendPackage (pyprev.pytz.override {tzdata = final.buildPackages.tzdata;}) {
  # pytest, not the native unittestCheckHook: unittest discovery imports
  # through the source pytz, which has no zoneinfo. test_suite is the
  # unittest.main() aggregator; under pytest it collects nothing.
  passthru = old:
    old
    // {
      wasixDeclaredCheckInputs = [pyfinal.pytestCheckHook];
    };
  pytestFlags = ["--import-mode=importlib"];
  disabledTests = ["test_suite"];
  # zone data does not resolve inside the check sandbox; PYTZ_TZDATADIR points
  # pytz at the same build-platform tzdata it bundles from
  env.PYTZ_TZDATADIR = "${final.buildPackages.tzdata}/share/zoneinfo";
}
