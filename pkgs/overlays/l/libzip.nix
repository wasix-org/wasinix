# zlib/xz/zstd auto-thread; withLZMA/withBzip2 are build options (kept).
{
  exposeWasixPackage,
  extendPackage,
  package,
  packages,
}:
exposeWasixPackage (
  (extendPackage (package.override {
    withLZMA = true;
    withBzip2 = false;
  }) {})
.overrideAttrs (o: {
    # libzip's cmake feature checks link conftests that the default wasm-opt pass
    # false-negatives; skip wasm-opt during configure.
    nativeBuildInputs = (o.nativeBuildInputs or []) ++ [packages.sameProfile.disableWasmOptInConfigureHook];
  })
)
