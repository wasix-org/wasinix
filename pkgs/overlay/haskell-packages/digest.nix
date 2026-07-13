# -f-pkg-config makes digest use the haskell zlib, not the system C zlib.
{
  hfinal,
  hprev,
  toolchain,
  ...
}:
toolchain.haskell.lib.overrideCabal hprev.digest (old: {
  configureFlags = (old.configureFlags or []) ++ ["-f-pkg-config"];
  libraryPkgconfigDepends = [];
  librarySystemDepends = [];
  libraryHaskellDepends = (old.libraryHaskellDepends or []) ++ [hfinal.zlib];
})
