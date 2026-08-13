# Host flang (x86) emitting wasm32-wasi objects; flang-rt is a separate cross build.
{pkgs}:
pkgs.llvmPackages_21.flang-unwrapped.overrideAttrs (old: {
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
