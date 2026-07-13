# pandoc as a wasm32-wasi command (wasmerPackages.pandoc): wasm-opt the pandoc-cli
# from the haskell set and ship it. GHC emits wasm32-wasi and ignores the profile
# EH/PIC flags, so it's one build at the preferred profile, not a per-profile set.
{
  final,
  helpers,
  toolchain,
  ...
}: let
  pandoc-cli = final.haskellPackages.pandoc-cli;
in
  # the standard ghc-wasm post-link wasm-opt pass.
  helpers.libTweaks {passthru.wasix.shipped = true;} (
    final.buildPackages.runCommand "pandoc" {
      inherit (pandoc-cli) version; # so the webc is pandoc-<ver>
      nativeBuildInputs = [toolchain.haskell.binaryen];
    } ''
      wasm-opt --experimental-new-eh --low-memory-unused --converge --gufa \
        --flatten --rereloop -Oz ${pandoc-cli}/bin/pandoc.wasm -o pandoc.opt.wasm
      install -Dm755 pandoc.opt.wasm "$out/bin/pandoc.wasm"
    ''
  )
