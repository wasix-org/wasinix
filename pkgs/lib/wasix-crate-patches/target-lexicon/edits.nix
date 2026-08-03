# target-lexicon: adds the wasm32-wasmer-wasi triple; the floor patch applies to
# any 0.12.15+ (a version it no longer applies to hard-fails for a fresh patch).
{...}: {
  edited = [">=0.12.15"];
}
