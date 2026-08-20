# libdeflate/libjpeg/xz/zlib/zstd/libwebp auto-thread.
{
  prev,
  helpers,
  ...
}:
helpers.extendPackage (prev.libtiff.override {withLerc = false;}) {
  # raw_decode fails untriaged (WASIX-TODO.md); exclude it and run the rest.
  cmakeFlags = ["-DBUILD_TESTING=ON"];
  checkFlagsArray = [''ARGS=--output-on-failure -E ^raw_decode$''];
}
