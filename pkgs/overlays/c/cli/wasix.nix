{
  exposeWasixPackage,
  lib,
  packages,
}:
exposeWasixPackage (
  let
    pname = "cli";
    version = "0.1.4";
    wasmerDependencies = import ../../../wasmer/dependencies.nix {inherit lib;};
    identityFiles = packages.sameProfile.symlinkJoin {
      name = "cli-identity-files";
      paths = [
        (packages.sameProfile.writeTextDir "passwd" "root:x:0:0:root:/:/bin/bash\n")
        (packages.sameProfile.writeTextDir "group" "root:x:0:\n")
      ];
    };
    tools = with packages.wasix.preferred; [
      coreutils
      curl
      findutils
      gnugrep
      gzip
      less
      nano
      ncurses-progs
      gnused
      gnutar
    ];
  in
    packages.sameProfile.runCommand "${pname}-${version}" {
      inherit pname version;
      meta.description = "Shell environment with common command-line tools";
      passthru = {
        wasinix.shipped = true;
        wasmer = {
          fs."/etc" = identityFiles;
          name = pname;
          entrypoint = "bash";
          commands = [
            {
              name = "bash";
              dependency = wasmerDependencies.exact packages.wasix.preferred.bash;
            }
          ];
          dependencies =
            map wasmerDependencies.exact
            tools;
        };
      };
    } ''
      mkdir -p "$out"
    ''
)
