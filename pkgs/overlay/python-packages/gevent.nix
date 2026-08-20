# gevent for wasix. nixpkgs links system libev/libuv/c-ares, none of which
# cross-build here, so embed the bundled libev (the CPython default loop) and drop
# the rest. libev's inner ./configure needs --host, else autoconf runs wasm probes.
{
  pyprev,
  helpers,
  ...
}:
helpers.extendPackage pyprev.gevent (
  helpers.linkInputs (helpers.dropInputsByNameInfix ["libev" "libuv" "c-ares"])
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
