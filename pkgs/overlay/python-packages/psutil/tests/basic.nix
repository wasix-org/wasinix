# What psutil can and cannot do on wasix, so a regression in either direction
# (an import that breaks, or a /proc that appears) shows up here.
{
  wheel,
  runPython,
  ...
}: {
  works = runPython {
    name = "psutil-works";
    inherit wheel;
    script = ''
      import psutil

      # sysconf-backed, so it answers
      assert psutil.cpu_count() >= 1, psutil.cpu_count()

      # the /proc-backed API has nothing to read here: it raises, it does not lie
      try:
          psutil.Process()
      except psutil.Error:
          pass
      else:
          raise AssertionError("Process() worked; does wasix have /proc now?")

      # users() is our stub: the sysroot has no utmpx
      try:
          psutil.users()
      except NotImplementedError:
          pass
      else:
          raise AssertionError("users() worked; drop the stub?")
    '';
  };
}
