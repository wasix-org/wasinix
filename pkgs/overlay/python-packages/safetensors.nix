# safetensors' read_exact_at has cfg(unix) and cfg(windows) arms but no fallback,
# so on wasi the body is empty and the fn returns () instead of io::Result<()>.
{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  patches = [./patches/safetensors-wasi-read-exact-at.patch];
}
pyprev.safetensors
