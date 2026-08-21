# libffi (behind Python's ctypes). Upstream's wasm32 backend is
# emscripten-specific, so carry wasix-org/libffi's wasi backend as a patch on
# the nixpkgs source (see wasi-backend.patch); the package follows nixpkgs'
# libffi, and a version bump that breaks the patch fails loudly. Also disable
# the multi-os-directory probe (runs `clang -print-multi-os-directory`,
# rejected by wasix-llvm's clang) and the raw API (inline asm).
{exposeExtendedPackage}:
exposeExtendedPackage {
  patches = [./wasi-backend.patch];
  configureFlags = ["--disable-multi-os-directory" "--disable-raw-api"];
}
