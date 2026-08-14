# Host flang (x86) emitting wasm32-wasi objects; flang-rt is a separate cross build.
# Built from the fork scope, so Fortran objects come out of the same WebAssembly
# backend as everything else: nixpkgs' llvm carries neither the multi-def
# stackify fix nor the non-emscripten TLS model the fork does.
{wasix-llvm, ...}:
wasix-llvm.passthru.llvm.flang-unwrapped.overrideAttrs (old: {
  # flang derives the target ABI from the host: no wasm case in Target.cpp, i64
  # _FortranA* lengths from RTBuilder.h, and a 3-arg main WASI's crt never calls.
  patches =
    (old.patches or [])
    ++ [
      ./flang-wasm32-target.patch
      ./flang-wasm32-runtime-abi.patch
      ./flang-wasm32-main.patch
      ./flang-wasm32-common-linkage.patch
    ];
  doCheck = false;
})
