# libffi for wasix (the dependency behind Python's ctypes). Upstream libffi's only wasm
# backend (src/wasm/ffi.c) is emscripten-specific (`#include <emscripten/emscripten.h>`), so
# it can't target wasix. The wasix-org/libffi fork adds a wasi backend (src/wasm32/ffi.c);
# base on it. Also disable the multi-os-directory probe (runs `clang -print-multi-os-directory`,
# which wasix-llvm's clang rejects) and the raw API (inline asm). Matches build-scripts.
{
  final,
  prev,
  ...
}:
prev.libffi.overrideAttrs (old: {
  src = final.fetchFromGitHub {
    owner = "wasix-org";
    repo = "libffi";
    rev = "09cbf7d66d232a01dbb0c88fd5ae65fa9c15f7c7";
    hash = "sha256-6xayw5iBCCXxTM37+1RmFdxptvgcrKlxOqjaMyBb16I=";
  };
  # the fork ships configure.ac only.
  nativeBuildInputs = (old.nativeBuildInputs or []) ++ [final.buildPackages.autoreconfHook];
  configureFlags =
    (old.configureFlags or [])
    ++ ["--disable-multi-os-directory" "--disable-raw-api" "--disable-docs"];
  # --disable-docs skips the texinfo build, so the `info` output is never produced (nix then
  # errors). Drop it.
  outputs = prev.lib.filter (o: o != "info") old.outputs;
})
