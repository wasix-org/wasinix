# Packages needing no wasix tweaks beyond doCheck=false, each built as
# `libTweaks {} prev.<name>`. Move one to packages/<name>.nix as soon as it
# needs a flag/patch/test/passthru.
[
  "brotli"
  "bzip2"
  "editline" # nix repl
  "expat"
  "jansson"
  "lcms2" # pillow's ImageCms
  "libb2"
  "libblake3" # nix
  "libdeflate" # ctest suite runs under wasmer as-is
  "libyaml" # pyyaml C ext (langchain/litellm/smolagents pull pyyaml)
  "lz4"
  "mpfr"
  "oniguruma"
  "openjpeg"
  "popt" # rsync
  "tinyxml-2"
  "xz"
]
