# sqlite's configure libm check links a conftest, and the default wasm-opt
# pass false-negatives it ("Cannot find libm functions"); skip wasm-opt during
# configure.
{
  final,
  prev,
  helpers,
  ...
}:
(helpers.extendPackage prev.sqlite {}).overrideAttrs (o: {
  nativeBuildInputs = (o.nativeBuildInputs or []) ++ [final.disableWasmOptInConfigureHook];
})
