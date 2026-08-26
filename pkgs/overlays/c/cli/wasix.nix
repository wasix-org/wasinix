{
  exposeWasixPackage,
  packages,
}:
exposeWasixPackage (
  let
    pname = "cli";
    version = "0.1.4";
    tools = with packages.wasix.preferred; [
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
          name = pname;
          entrypoint = "bash";
          commands = [
            {
              name = "bash";
              dependency = {
                package = packages.wasix.preferred.bash;
                version = "*";
              };
            }
          ];
          dependencies =
            map (package: {
              inherit package;
              version = "*";
            })
            tools;
        };
      };
    } ''
      mkdir -p "$out"
    ''
)
