{
  prev,
  helpers,
  ...
}:
helpers.libTweaks {
  patches = [./patches/wasi-is-not-the-js-wasm-build.patch];
}
prev.llhttp
