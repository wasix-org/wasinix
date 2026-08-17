{
  pyprev,
  pyfinal,
  helpers,
  ...
}:
helpers.libTweaks {
  passthru.wasixDeclaredCheckInputs = [pyfinal.numpy pyfinal.setuptools];
  passthru.wasix.emulatedCheck.timeout = 3600;
  installCheckPhase = _: ''
    export HOME="$NIX_BUILD_TOP"
    ${pyfinal.python.interpreter} runtests.py -j1 --no-code-style --cython-only --no-refnanny
  '';
}
pyprev.cython
