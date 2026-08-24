# target-lexicon: adds the wasm32-wasmer-wasi triple; the floor patch applies to
# any version at or above its own (a version it no longer applies to hard-fails
# for a fresh patch). 0.12.15 reordered the enums 0.12.14 patches, hence two.
_: {
  edited = [">=0.12.14"];
}
