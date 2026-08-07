{
  final,
  helpers,
  preferredProfilePackages,
  toolchain,
  ...
}:
helpers.libTweaks {
  passthru.wasix.shipped = true;
  passthru.wasmer = {
    dependencies = [preferredProfilePackages.bash];
    commandEnv = {
      anybuild.PATH = "/bin:/usr/bin";
      shipit.PATH = "/bin:/usr/bin";
    };
  };
} (toolchain.anybuild.override {
  inherit (final) rustPlatform stdenv;
  shellPath = "/bin/bash";
})
