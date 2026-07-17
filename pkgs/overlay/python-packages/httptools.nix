# httptools for wasix. Vendored llhttp guards its JS-embedder API with bare
# __wasm__: extern wasm_on_* callbacks the (browser) host must provide, plus a
# wasm_settings table wired to them, so a wasi build imports unresolvable
# GOT symbols and the module fails to load. Admit wasi back to the normal C
# path; the right upstream (llhttp) fix is gating on __EMSCRIPTEN__ or a
# dedicated macro instead of __wasm__.
{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  postPatch = ''
    substituteInPlace vendor/llhttp/src/api.c \
      --replace-fail '#if defined(__wasm__)' '#if defined(__wasm__) && !defined(__wasi__)'
  '';
}
pyprev.httptools
