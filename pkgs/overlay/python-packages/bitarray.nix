{
  final,
  pyprev,
  pyfinal,
  helpers,
  ...
}:
helpers.libTweaks {
  # The guest exits zero after bitarray.test(), so check unittest's summary.
  checkPhase = ''
    cd $out
    _log="$NIX_BUILD_TOP/bitarray-test.log"
    ${pyfinal.python.interpreter} -c 'import bitarray; bitarray.test()' 2>&1 | ${final.buildPackages.coreutils}/bin/tee "$_log"
    ${final.buildPackages.gnugrep}/bin/grep -qx OK "$_log" || exit 1
  '';
  passthru.wasix.emulatedCheck.broken = "WASIX reports bitarray objects as hashable";
}
pyprev.bitarray
