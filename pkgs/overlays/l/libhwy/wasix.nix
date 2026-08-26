# stdenv.nix strips highway's hardcoded -fno-exceptions for the cross build.
{
  exposeWasixExtendedPackage,
  profileSets,
}:
exposeWasixExtendedPackage {
  passthru.wasix.supportedProfiles = profileSets.pic;
  # contrib/thread_pool includes <emscripten/threading.h> on any __wasm__ target.
  patches = [
    ./highway-wasi-emscripten-only-futex.patch
  ];
}
