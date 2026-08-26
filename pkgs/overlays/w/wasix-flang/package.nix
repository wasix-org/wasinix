# Host flang (x86) emitting wasm32-wasi objects; flang-rt is a separate cross build.
# Built from the fork scope, so Fortran objects come out of the same WebAssembly
# backend as everything else: nixpkgs' llvm carries neither the multi-def
# stackify fix nor the non-emscripten TLS model the fork does.
{
  exposePackage,
  packageSet,
}:
exposePackage (packageSet.callPackage ({wasix-llvm, ...}:
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
      passthru.wasix.supportedProfiles = [];
      meta =
        (old.meta or {})
        // {
          description = "WASIX LLVM Flang frontend";
          longDescription = "The LLVM Flang frontend from the WASIX LLVM fork, configured to emit WebAssembly objects for the WASIX toolchain.";
          homepage = "https://github.com/wasix-org/llvm-project";
          changelog = "https://github.com/wasix-org/llvm-project/releases/tag/${wasix-llvm.passthru.version}";
          license = wasix-llvm.meta.license;
        };
    })) {})
