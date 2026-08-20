# The extension links -lre2 alone, and a static re2 does not carry its abseil
# dependencies. The PIC dylib link turns the undefined data symbols into GOT
# imports rather than failing, so the miss only surfaces as an unresolved
# `kSooControl` when wasmer loads the module; link abseil explicitly.
{
  pyprev,
  final,
  helpers,
  ...
}: let
  absl = final.abseil-cpp;
in
  helpers.extendPackage pyprev.google-re2 {
    buildInputs = [absl];
    # The -l set is enumerated in the build, where abseil is an input anyway;
    # an eval-time readDir would import-from-derivation the whole toolchain.
    preConfigure = ''
      NIX_LDFLAGS="$NIX_LDFLAGS -L${absl}/lib"
      for _lib in ${absl}/lib/lib*.a; do
        _lib=''${_lib##*/lib}
        NIX_LDFLAGS="$NIX_LDFLAGS -l''${_lib%.a}"
      done
      export NIX_LDFLAGS
    '';
  }
