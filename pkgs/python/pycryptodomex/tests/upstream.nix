# The wheel ships pycryptodomex's SelfTest suite; run that rather than the
# source tree, whose Cryptodome/ has no compiled modules. slow_tests=0 is
# upstream's own --skip-slow-tests knob: it trims extra Wycheproof
# vector sizes, not test classes. nixpkgs itself never runs this suite
# (pythonImportsCheck only), so this covers strictly more than upstream.
{
  wheel,
  runPython,
}: {
  upstream = runPython {
    name = "wheel-pytest-pycryptodomex";
    inherit wheel;
    timeout = 1800;
    script = ''
      import unittest
      from Cryptodome.SelfTest import get_tests

      suite = unittest.TestSuite(get_tests(config={"slow_tests": 0}))
      result = unittest.TextTestRunner(verbosity=1).run(suite)
      if not result.wasSuccessful():
          raise SystemExit("pycryptodomex SelfTest failed")
    '';
  };
}
