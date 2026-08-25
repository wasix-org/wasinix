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
  exposePackage,
  packages,
  package,
  pkgs,
  lib,
}:
exposePackage (
  let
    inherit (pkgs) stdenv;
    base = package.override {
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
      dependencies = (o.dependencies or []) ++ [packages.sameProfile.psycopg];
    });
  in
    base.overridePythonAttrs (o: {
      # nixpkgs bakes libpq's store path into the pure-python ctypes fallback
      # (_pq_ctypes.py). That impl is never reached (psycopg_c is present) and
      # the path is dead anyway (libpq is static, no libpq.so), so scrub it to a
      # bare name: the wheel ships no /nix/store ref and stays pip-relocatable.
      postPatch =
        (o.postPatch or "")
        + ''
          substituteInPlace psycopg/pq/_pq_ctypes.py \
            --replace-quiet "${lib.getLib pkgs.libpq}/lib/libpq.so" "libpq.so"
        '';
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
          # Replaces the stashed check inputs: the inherited list drags
          # psycopg-c, which does not cross-build; anyio brings the plugin that
          # owns the anyio mark.
          wasixDeclaredCheckInputs = [packages.sameProfile.pytestCheckHook packages.sameProfile.pytest-asyncio packages.sameProfile.anyio];
          # No suite: the libpq dylib fails symbol resolution mid-run
          # ("pg_vsnprintf"), killing the session; WASIX-TODO.md tracks the
          # dylib symbol-resolution defect.
          wasinix = ((o.passthru or {}).wasinix or {}) // {checks.captured.install = false;};
        };
    })
)
