# on wasm the haskell zlib uses bundled zlib-clib; drop nixpkgs' system C-zlib
# (doesn't cross-compile) and add zlib-clib.
{
  hfinal,
  hprev,
  toolchain,
  ...
}:
toolchain.haskell.lib.overrideCabal hprev.zlib (old: {
  librarySystemDepends = [];
  libraryPkgconfigDepends = [];
  libraryHaskellDepends = (old.libraryHaskellDepends or []) ++ [hfinal.zlib-clib];
})
