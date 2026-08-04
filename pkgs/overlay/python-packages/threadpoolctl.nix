# threadpoolctl for wasix. ThreadpoolController enumerates loaded thread-pool
# libraries through dl_iterate_phdr, reached via ctypes.CDLL(libc.so), which the
# static wasix build fails with OSError ("libc.so: entry not found"), taking any
# consumer with it. Skip enumeration, as threadpoolctl already does for pyodide.
{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  postPatch = ''
    substituteInPlace threadpoolctl.py --replace-fail \
      'self._find_libraries_with_dl_iterate_phdr()' \
      '(None if sys.platform.startswith("wasi") else self._find_libraries_with_dl_iterate_phdr())'
  '';
}
pyprev.threadpoolctl
