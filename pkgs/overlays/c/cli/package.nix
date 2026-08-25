{
  exposePackageVariants,
  packageSet,
  packages,
}: let
  pname = "cli";
  version = "0.1.4";
  nativeTools = with packageSet; [
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
  wasixTools = with packages.preferred; [
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
  native = packageSet.symlinkJoin {
    name = "${pname}-${version}";
    paths = nativeTools;
    meta.description = "Shell environment with common command-line tools";
  };
  wasix =
    packageSet.runCommand "${pname}-${version}" {
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
                package = packages.preferred.bash;
                version = "*";
              };
            }
          ];
          dependencies =
            map (package: {
              inherit package;
              version = "*";
            })
            wasixTools;
        };
      };
    } ''
      mkdir -p "$out"
    '';
in
  exposePackageVariants {inherit native wasix;}
