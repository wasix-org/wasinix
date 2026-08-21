# xxHash (C libxxhash; pulled into the closure via zstd, and by rsync). 0.8.3
# treats the toolchain's -msimd128 (__wasm_simd128__) as "WASM SIMD128 via
# SIMDe" and #includes <arm_neon.h> expecting SIMDe to supply it, but clang
# ships the real ARM header ("intended only for ARM"). Neutralise that path so
# wasm uses the scalar code (XXH_VECTOR guards don't cover the bare #include).
{exposeExtendedPackage}:
exposeExtendedPackage {
  postPatch = ''
    substituteInPlace xxhash.h \
      --replace-quiet 'defined(__wasm_simd128__) && XXH_HAS_INCLUDE(<arm_neon.h>)' '0'
  '';
}
