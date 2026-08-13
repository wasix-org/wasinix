# Packages needing no wasix tweaks beyond doCheck=false, each built as
# `libTweaks {} prev.<name>`. Move one to packages/<name>.nix as soon as it
# needs a flag/patch/test/passthru.
[
  "brotli"
  "bzip2"
  "editline" # nix repl
  "expat"
  "gmp"
  "jansson"
  "lcms2" # pillow's ImageCms
  "libb2"
  "libdeflate"
  "libblake3" # nix
  "libpng"
  "libsodium"
  "libyaml" # pyyaml C ext (langchain/litellm/smolagents pull pyyaml)
  "lz4"
  "lzo"
  "mpfr"
  "nlohmann_json" # nix
  "oniguruma"
  "openjpeg"
  "popt" # rsync
  "tinyxml-2"
  "toml11" # nix
  "xz"
]
