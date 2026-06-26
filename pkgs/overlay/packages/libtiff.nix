# libdeflate/libjpeg/xz/zlib/zstd/libwebp auto-thread.
{
  prev,
  helpers,
  ...
}:
helpers.libTweaks {} (prev.libtiff.override {withLerc = false;})
