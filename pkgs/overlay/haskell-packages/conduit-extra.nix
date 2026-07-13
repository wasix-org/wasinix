# no sockets: drop the network modules. editedCabalFile=null forces the LF sdist
# cabal, since the Hackage revision is CRLF and breaks the patch.
{
  hprev,
  toolchain,
  ...
}:
toolchain.haskell.lib.overrideCabal hprev.conduit-extra (old: {
  editedCabalFile = null;
  revision = null;
  patches = (old.patches or []) ++ [./patches/conduit-extra/wasi-drop-network.patch];
  libraryHaskellDepends = (import ./lib/deps.nix).dropDeps ["network"] old.libraryHaskellDepends;
})
