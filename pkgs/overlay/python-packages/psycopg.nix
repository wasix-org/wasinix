# psycopg for wasix. nixpkgs substitutes ctypes dlopen paths into the pure-python
# impl via `${stdenv.cc.libc}/lib/libc.so.6` and `extensions.sharedLibrary`; the
# wasix stdenv has cc.libc = null and wasm32-wasi no sharedLibrary extension,
# killing eval for psycopg and its passthru (psycopg-c, psycopg-pool). The ctypes
# impl can't work here anyway (libpq builds static-only, and there's no libc.so.6),
# so feed the patch harmless strings; imports go through the compiled psycopg_c.
# psycopg-c's vendored portable-endian header only reaches <endian.h> under
# __linux__; wasix libc ships it, so admit __wasi__ too. The fixed psycopg-c is
# swapped into psycopg's propagation and passthru (psycopg-c/-pool resolve
# through the latter).
{
  final,
  lib,
  pyfinal,
  pyprev,
  ...
}: let
  stdenv = final.stdenv;
  base = pyprev.psycopg.override {
    stdenv =
      stdenv
      // {
        cc = stdenv.cc // {libc = "/nonexistent-wasix-has-no-glibc";};
        hostPlatform =
          stdenv.hostPlatform
          // {
            extensions = stdenv.hostPlatform.extensions // {sharedLibrary = ".so";};
          };
      };
  };
  psycopg-c = base.passthru.c.overridePythonAttrs (o: {
    postPatch =
      (o.postPatch or "")
      + ''
        substituteInPlace psycopg_c/_psycopg/endian.pxd \
          --replace-fail 'defined(__linux__) || defined(__CYGWIN__)' \
                         'defined(__linux__) || defined(__CYGWIN__) || defined(__wasi__)'
      '';
  });
  # upstream psycopg-pool declares a psycopg dependency; nixpkgs drops it
  # (both come from the one repo), leaving the wheel unimportable alone.
  psycopg-pool = base.passthru.pool.overridePythonAttrs (o: {
    dependencies = (o.dependencies or []) ++ [pyfinal.psycopg];
  });
in
  base.overridePythonAttrs (o: {
    propagatedBuildInputs = map (d:
      if (d.pname or "") == "psycopg-c"
      then psycopg-c
      else d)
    o.propagatedBuildInputs;
    passthru =
      o.passthru
      // {
        c = psycopg-c;
        pool = psycopg-pool;
      };
  })
