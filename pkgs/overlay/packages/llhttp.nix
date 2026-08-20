{
  helpers,
  prev,
  ...
}:
helpers.extendPackage prev.llhttp {
  # __wasm__ enables Node embedder callbacks that WASIX does not provide.
  # __wasi__ excludes WASIX without changing Node's Emscripten build.
  postPatch = ''
    substituteInPlace src/api.c \
      --replace-fail '#if defined(__wasm__)' '#if defined(__wasm__) && !defined(__wasi__)'
  '';
}
