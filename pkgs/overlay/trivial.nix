# Packages needing no wasix-specific tweaks beyond doCheck=false — each built as
# `libTweaks {} prev.<name>`. Listed here rather than as a one-line file apiece,
# since a no-diff package doesn't warrant a file. Promote to packages/<name>.nix
# (or a packages/<name>/ dir) the moment it needs a flag/patch/test/passthru.
[
  "expat"
  "libdeflate"
  "libpng"
  "libsodium"
  "oniguruma"
  "xz"
]
