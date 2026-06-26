# sqlite's configure libm check links a conftest, and the default wasm-opt pass
# false-negatives it ("Cannot find libm functions") — so skip wasm-opt during
# configure. Otherwise a plain library (would be in trivial.nix).
{
  final,
  prev,
  helpers,
  ...
}:
(helpers.libTweaks {} prev.sqlite).overrideAttrs (o: {
  nativeBuildInputs = (o.nativeBuildInputs or []) ++ [final.disableWasmOptInConfigureHook];
})
