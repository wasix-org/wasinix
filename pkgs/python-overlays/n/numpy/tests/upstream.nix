# numpy ships its test suite inside the wheel, so run that rather than the
# source tree (whose numpy/ package would shadow the compiled modules).
{
  wheel,
  harnesses,
  pythonPkgs,
}: {
  upstream = harnesses.python {
    name = "wheel-pytest-numpy";
    inherit wheel;
    deps = [pythonPkgs.pytest pythonPkgs.hypothesis];
    timeout = 1200;
    ciTags = ["slow-tests"];
    # Deselections are environment gaps, not numpy defects: test_cpu_features
    # spawns subprocesses with cwd (unsupported on wasix, subprocess-posix-spawn-wasi.patch);
    # test_exp_exceptions/test_exp2 assert FloatingPointError, which wasm never
    # raises (<fenv.h>, WASIX-TODO.md); test_largish_file writes and rewrites a
    # 64MB file, several times over per filename-type parametrization.
    script = ''
      import os, tempfile
      os.makedirs("/home/tmp", exist_ok=True)
      os.environ["TMPDIR"] = "/home/tmp"
      tempfile.tempdir = "/home/tmp"

      import faulthandler
      for _n in ("enable", "dump_traceback_later", "cancel_dump_traceback_later"):
          setattr(faulthandler, _n, lambda *a, **k: None)

      import numpy
      skip = ("not (test_runtime_feature_selection or test_both_enable_disable_set"
              " or test_largish_file or test_exp_exceptions or test_exp2)")
      if not numpy.test(verbose=1, extra_argv=["-p", "no:cacheprovider", "-o", "addopts=", "-k", skip]):
          raise SystemExit("numpy test suite failed")
    '';
  };
}
