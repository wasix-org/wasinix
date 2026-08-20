{
  final,
  pyprev,
  pyfinal,
  helpers,
  ...
}:
helpers.libTweaks {
  # The guest exits zero after bitarray.test(), so check unittest's summary.
  installCheckPhase = _: ''
    cd $out
    _log="$NIX_BUILD_TOP/bitarray-test.log"
    ${pyfinal.python.interpreter} -c 'import bitarray; bitarray.test()' 2>&1 | ${final.lib.getExe' final.buildPackages.coreutils "tee"} "$_log"
    ${final.lib.getExe final.buildPackages.gnugrep} -qx OK "$_log"
  '';
  passthru.wasinix.checks.captured.broken = "WASIX reports bitarray objects as hashable";
}
pyprev.bitarray
