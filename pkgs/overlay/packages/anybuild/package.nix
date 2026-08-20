{
  prev,
  helpers,
  preferredProfilePackages,
  wasmerDependencies,
  ...
}:
helpers.libTweaks {
  passthru.wasinix.shipped = true;
  passthru.wasmer = {
    entrypoint = "anybuild";
    dependencies = [(wasmerDependencies.any preferredProfilePackages.bash)];
    commandEnv = {
      anybuild.PATH = "/bin:/usr/bin";
      shipit.PATH = "/bin:/usr/bin";
    };
  };
}
(prev.anybuild.override {shellPath = "/bin/bash";})
