# Shared wasm32-wasi Fortran cross settings for the host flang.
{lib}: {
  # flang rejects clang's -m<feature> spellings, so ABI features go through
  # -Xflang. +exception-handling only sets the feature bit for ABI consistency
  # with the C objects; the emitted code carries no EH instructions.
  mkFortranFlags = {
    pic ? false,
    eh ? false,
  }:
    lib.concatStringsSep " " (
      [
        "--target=wasm32-wasi"
        "-Xflang -target-feature -Xflang +atomics"
        "-Xflang -target-feature -Xflang +bulk-memory"
        "-Xflang -target-feature -Xflang +mutable-globals"
      ]
      ++ lib.optional eh "-Xflang -target-feature -Xflang +exception-handling"
      ++ lib.optional pic "-fPIC"
    );

  # FORCE-trusting the compiler skips cmake's Fortran probe, which links and runs a
  # wasm executable. CMAKE_Fortran_FLAGS stays out; its -Xflang pairs carry spaces.
  mkFortranProbeVars = {
    flang,
    version ? flang.version,
  }: [
    (lib.cmakeFeature "CMAKE_Fortran_COMPILER" (lib.getExe flang))
    (lib.cmakeFeature "CMAKE_Fortran_COMPILER_ID" "LLVMFlang")
    (lib.cmakeFeature "CMAKE_Fortran_COMPILER_VERSION" version)
    (lib.cmakeFeature "CMAKE_Fortran_COMPILER_TARGET" "wasm32-wasi")
    (lib.cmakeBool "CMAKE_Fortran_COMPILER_WORKS" true)
    (lib.cmakeBool "CMAKE_Fortran_COMPILER_FORCED" true)
  ];
}
