# sd: a sed-like find-replace tool in Rust. Just prev.sd; the wasix
# rustPlatform builds it, installs the .wasm, and sets the eh profile + meta.
{
  prev,
  helpers,
  ...
}:
helpers.libTweaks {passthru.wasix.shipped = true;} prev.sd
