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
    ${pyfinal.python.interpreter} -c 'import bitarray; raise SystemExit(not bitarray.test().wasSuccessful())'
  '';
  passthru.wasix.emulatedCheck.broken = "WASIX reports bitarray objects as hashable";
}
pyprev.bitarray
