# Packages needing no wasix tweaks beyond doCheck=false, each built as
# `libTweaks {} prev.<name>`. Move one to packages/<name>.nix as soon as it
# needs a flag/patch/test/passthru.
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
  "libyaml" # pyyaml C ext (langchain/litellm/smolagents pull pyyaml)
  "lz4"
  "lzo"
  "mpfr"
  "oniguruma"
  "openjpeg"
  "popt" # rsync
  "tinyxml-2"
  "xz"
]
