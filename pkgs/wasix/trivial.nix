# Packages needing no WASIX-specific changes. Move one to
# packages/<name>.nix as soon as it needs a flag, patch, test, or metadata.
[
  "brotli"
  "bzip2"
  "editline" # nix repl
  "expat"
  "giflib"
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
