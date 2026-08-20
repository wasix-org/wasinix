{
  final,
  preferredProfilePackages,
  wasmerDependencies,
  ...
}: let
  pname = "cli";
  version = "0.1.4";
  tools = with preferredProfilePackages; [
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
  final.runCommand "${pname}-${version}" {
    inherit pname version;
    meta.description = "Shell environment with common command-line tools";
    passthru = {
      wasix.shipped = true;
      wasmer = {
        name = pname;
        entrypoint = "bash";
        commands = [
          {
            name = "bash";
            dependency = wasmerDependencies.any preferredProfilePackages.bash;
          }
        ];
        dependencies = map wasmerDependencies.any tools;
      };
    };
  } ''
    mkdir -p "$out"
  ''
