{
  prev,
  helpers,
  ...
}:
helpers.extendPackage prev.llhttp {
  patches = [./patches/wasi-is-not-the-js-wasm-build.patch];
}
