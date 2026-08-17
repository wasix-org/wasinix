{
  pyprev,
  pyfinal,
  helpers,
  ...
}:
helpers.libTweaks {
  # bitarray.test reports failure in its return value rather than raising.
  checkPhase = ''
    cd $out
    export BITARRAY_CHECK_STATUS="$NIX_BUILD_TOP/bitarray-check-failed"
    touch "$BITARRAY_CHECK_STATUS"
    ${pyfinal.python.interpreter} -c 'import os; from pathlib import Path; import bitarray; bitarray.test().wasSuccessful() and Path(os.environ["BITARRAY_CHECK_STATUS"]).unlink()'
    test ! -e "$BITARRAY_CHECK_STATUS"
  '';
  passthru.wasix.emulatedCheck.broken = "WASIX reports bitarray objects as hashable";
}
pyprev.bitarray
