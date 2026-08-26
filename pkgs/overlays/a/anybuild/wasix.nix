{
  exposeWasixPackage,
  extendPackage,
  package,
  packages,
}:
exposeWasixPackage (
  extendPackage (package.override {shellPath = "/bin/bash";}) {
    passthru.wasinix.shipped = true;
    passthru.wasmer = {
      entrypoint = "anybuild";
      dependencies = [
        {
          package = packages.wasix.preferred.bash;
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
