# sqlite's configure libm check links a conftest, and the default wasm-opt
# pass false-negatives it ("Cannot find libm functions"); skip wasm-opt during
# configure.
{
  exposeExtendedPackage,
  packages,
}:
exposeExtendedPackage {
  nativeBuildInputs = [packages.sameProfile.disableWasmOptInConfigureHook];
}
