# pytz for wasix. pytz bundles ${tzdata}/share/zoneinfo, but the cross tzdata doesn't build
# (zic uses getresuid etc.). zoneinfo is platform-independent, so use the build-platform tzdata.
{
  pyprev,
  final,
  ...
}:
pyprev.pytz.override {tzdata = final.buildPackages.tzdata;}
