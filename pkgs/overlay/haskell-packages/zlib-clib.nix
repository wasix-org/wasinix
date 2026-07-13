# bundled C zlib uses errno without errno.h under -DNO_STRERROR on wasi.
{
  hprev,
  toolchain,
  ...
}:
toolchain.haskell.lib.overrideCabal hprev.zlib-clib (old: {
  patches = (old.patches or []) ++ [./patches/zlib-clib/wasi-errno.patch];
})
