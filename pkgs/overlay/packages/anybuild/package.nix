{
  final,
  helpers,
  preferredProfilePackages,
  wasmerDependencies,
  toolchain,
  ...
}:
helpers.libTweaks {
  passthru.wasix.shipped = true;
  passthru.wasmer = {
    entrypoint = "anybuild";
    dependencies = [(wasmerDependencies.any preferredProfilePackages.bash)];
    commandEnv = {
      anybuild.PATH = "/bin:/usr/bin";
      shipit.PATH = "/bin:/usr/bin";
    };
  };
} (toolchain.anybuild.override {
  inherit (final) rustPlatform stdenv;
  shellPath = "/bin/bash";
})
