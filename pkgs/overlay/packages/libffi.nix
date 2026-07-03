# libffi (behind Python's ctypes). Upstream's only wasm backend is
# emscripten-specific, so base on the wasix-org/libffi fork, which adds a wasi
# backend (src/wasm32/ffi.c). Also disable the multi-os-directory probe (runs
# `clang -print-multi-os-directory`, rejected by wasix-llvm's clang) and the
# raw API (inline asm).
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
  passthru =
    (old.passthru or {})
    // {
      wasix.updateReminders = [
        {
          writtenFor = "3.5.2";
          message = "src pins a wasix-org/libffi fork rev; on a libffi bump, refresh the fork pin or check whether upstream gained a non-emscripten wasm backend";
        }
      ];
    };
})
