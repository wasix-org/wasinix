# Packages needing no wasix-specific tweaks beyond doCheck=false — each built as
# `libTweaks {} prev.<name>`. Listed here rather than as a one-line file apiece,
# since a no-diff package doesn't warrant a file. Promote to packages/<name>.nix
# (or a packages/<name>/ dir) the moment it needs a flag/patch/test/passthru.
[
  "brotli"
  "bzip2"
  "expat"
  "giflib"
  "gmp"
  "jansson"
  "libb2"
  "libdeflate"
  "libpng"
  "libsodium"
  "lz4"
  "lzo"
  "mpfr"
  "oniguruma"
  "openjpeg"
  "tinyxml-2"
  "xz"
]
