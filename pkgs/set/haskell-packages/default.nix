# wasix overrides for the haskell package set (toolchain.haskell.packages), the
# analogue of python-packages/. Each <name>.nix overrides that package for wasm;
# patches under patches/. hfinal/hprev are the set fixpoint, haskellLib is
# haskell.lib, dropDeps filters *HaskellDepends by name.
{callArgs}: hfinal: hprev:
(callArgs.helpers.loadPackageDir {dir = ./.;}).mkPackages {
  callArgs = callArgs // {inherit hfinal hprev;};
}
