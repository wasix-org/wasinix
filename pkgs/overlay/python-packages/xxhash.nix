# The bundled xxhash sees __wasm_simd128__ (wasixcc >= 0.4.3 passes -msimd128
# by default) and includes <arm_neon.h>, expecting SIMDe's polyfill; it finds
# clang's builtin ARM header instead, which #errors on non-ARM targets.
# Defeat the include probe so xxhash falls back to scalar code.
{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  env.NIX_CFLAGS_COMPILE = "-DXXH_HAS_INCLUDE(h)=0";
  preCheck = ''
    mv xxhash xxhash.source
  '';
  pytestFlags = ["--import-mode=importlib"];
}
pyprev.xxhash
