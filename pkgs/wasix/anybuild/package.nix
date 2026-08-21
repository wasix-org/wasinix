{
  exposePackage,
  extendPackage,
  package,
  packages,
}:
exposePackage (
  extendPackage (package.override {shellPath = "/bin/bash";}) {
    passthru.wasinix.shipped = true;
    passthru.wasmer = {
      entrypoint = "anybuild";
      dependencies = [
        {
          package = packages.preferred.bash;
          version = "*";
        }
      ];
      commandEnv = {
        anybuild.PATH = "/bin:/usr/bin";
        shipit.PATH = "/bin:/usr/bin";
      };
    };
  }
)
