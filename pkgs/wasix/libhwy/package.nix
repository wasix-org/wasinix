# stdenv.nix strips highway's hardcoded -fno-exceptions for the cross build.
{
  prev,
  helpers,
  ...
}:
helpers.extendPackage prev.libhwy {
  # contrib/thread_pool includes <emscripten/threading.h> on any __wasm__ target.
  patches = [
    ./highway-wasi-emscripten-only-futex.patch
  ];
  passthru.wasix.supportedProfiles = helpers.profiles.pic;
}
