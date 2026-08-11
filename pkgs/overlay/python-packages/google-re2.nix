# The extension links -lre2 alone, and a static re2 does not carry its abseil
# dependencies. The PIC dylib link turns the undefined data symbols into GOT
# imports rather than failing, so the miss only surfaces as an unresolved
# `kSooControl` when wasmer loads the module; link abseil explicitly.
{
  pyprev,
  final,
  helpers,
  lib,
  ...
}: let
  absl = final.abseil-cpp;
  libs =
    map (f: "-l" + lib.removeSuffix ".a" (lib.removePrefix "lib" f))
    (builtins.filter (lib.hasSuffix ".a") (builtins.attrNames (builtins.readDir "${absl}/lib")));
in
  helpers.libTweaks {
    buildInputs = [absl];
    env.NIX_LDFLAGS = "-L${absl}/lib " + lib.concatStringsSep " " libs;
  }
  pyprev.google-re2
