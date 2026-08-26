{
  exposePackageVariants,
  extendPackage,
  packageSet,
  packages,
}: let
  native = packageSet.callPackage ./build.nix {};
  wasix = extendPackage (native.override {shellPath = "/bin/bash";}) {
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
  };
in
  exposePackageVariants {inherit native wasix;}
