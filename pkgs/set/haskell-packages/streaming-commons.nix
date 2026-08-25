# no sockets: drop the network modules.
{
  hprev,
  toolchain,
  ...
}:
toolchain.haskell.lib.overrideCabal hprev.streaming-commons (old: {
  patches = (old.patches or []) ++ [./patches/streaming-commons/wasi-drop-network.patch];
  libraryHaskellDepends = (import ./lib/deps.nix).dropDeps ["network"] old.libraryHaskellDepends;
})
