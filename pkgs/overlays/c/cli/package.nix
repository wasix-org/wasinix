{
  exposePackage,
  packageSet,
}: let
  tools = with packageSet; [
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
  exposePackage (packageSet.symlinkJoin {
    name = "cli-0.1.4";
    paths = tools;
    meta.description = "Shell environment with common command-line tools";
  })
