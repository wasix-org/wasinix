# WASIX libc provides iconv; keep the nixpkgs shim rather than GNU libiconv.
# The shim ships no archive (the symbols live in libc), so no link smoke.
{
  prev,
  helpers,
  ...
}:
helpers.extendPackage prev.libiconv {passthru.wasix.smokeTest = false;}
