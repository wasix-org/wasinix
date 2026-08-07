{
  final,
  helpers,
  preferredProfilePackages,
  toolchain,
  ...
}:
helpers.libTweaks {
  passthru.wasix.shipped = true;
  passthru.wasmer.dependencies = [preferredProfilePackages.bash];
} (toolchain.anybuild.override {
  inherit (final) rustPlatform stdenv;
  shellPath = "/bin/bash";
})
