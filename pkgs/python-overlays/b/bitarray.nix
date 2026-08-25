{
  exposeExtendedPackage,
  packages,
  pkgs,
}:
exposeExtendedPackage {
  # The guest exits zero after bitarray.test(), so check unittest's summary.
  installCheckPhase = _: ''
    cd $out
    _log="$NIX_BUILD_TOP/bitarray-test.log"
    ${packages.sameProfile.python.interpreter} -c 'import bitarray; bitarray.test()' 2>&1 | ${pkgs.lib.getExe' pkgs.buildPackages.coreutils "tee"} "$_log"
    ${pkgs.lib.getExe pkgs.buildPackages.gnugrep} -qx OK "$_log"
  '';
  passthru.wasinix.checks.captured.broken = "WASIX reports bitarray objects as hashable";
}
