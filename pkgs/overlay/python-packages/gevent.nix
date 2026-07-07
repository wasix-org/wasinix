# gevent for wasix. nixpkgs links system libev/libuv/c-ares (GEVENTSETUP_EMBED=0);
# none of those cross-build here, so embed the bundled libev instead. c-ares and the
# libuv cffi backend are dropped: the CPython default loop is the cython corecext
# (libev), the default resolver is 'thread', and bundled libuv needs a pile of wasix
# patches. libev's inner ./configure gets --host so autoconf cross-detects instead of
# trying to run wasm test binaries.
{
  pyprev,
  lib,
  helpers,
  ...
}: let
  wheels = import ./lib/wheels.nix {inherit lib;};
in
  # wasm build only: the native build must keep the nixpkgs system-libs setup.
  wheels.onlyOnWasix pyprev.gevent (
    helpers.libTweaks (
      wheels.dropInputsByName ["libev" "libuv" "c-ares"]
      // {
        env = {
          GEVENTSETUP_EMBED = "1";
          GEVENTSETUP_DISABLE_ARES = "1";
        };
        postPatch = ''
          substituteInPlace setup.py \
            --replace-fail "cffi_modules.append(LIBUV_CFFI_MODULE)" ""
          substituteInPlace _setuplibev.py \
            --replace-fail 'sh ./configure -C' 'sh ./configure -C --host=wasm32-wasi'
        '';
      }
    )
    pyprev.gevent
  )
