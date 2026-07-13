# shared helpers for the haskell overrides (like python-packages/lib/).
{
  # drop *HaskellDepends entries by exact package name: nixpkgs takes deps from
  # hackage2nix, not the patched cabal, so a dep a wasm patch removes must also be
  # filtered here.
  dropDeps = names: builtins.filter (d: !(builtins.elem (d.pname or "") names));
}
