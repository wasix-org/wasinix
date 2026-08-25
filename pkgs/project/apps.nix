{
  lib,
  project,
  projectAttr,
}: let
  pkgs = project.internals.packageSets.nativeRaw;
  core = project.packages.native.wasinix;
  capabilities = {
    aws = pkgs.awscli2;
    python = pkgs.python3;
    python-index = project.artifacts.registry.python.indexer;
    inherit (pkgs) rclone;
    wasmer = project.packages.native.wasmer;
  };
  cli = core.withCapabilities capabilities;
  commandNames = ["wasinix"] ++ core.commandAliases;
  commandFor = name:
    pkgs.writeShellApplication {
      inherit name;
      inheritPath = false;
      runtimeInputs = [cli];
      text = ''
        export WASINIX_PROJECT=${lib.escapeShellArg ".#${projectAttr}"}
        exec wasinix ${lib.optionalString (name != "wasinix") name} "$@"
      '';
    };
  commands = lib.genAttrs commandNames commandFor;
in {
  inherit capabilities cli;
  apps = lib.mapAttrs (name: command: {
    type = "app";
    program = lib.getExe command;
    meta = (command.meta or {}) // {description = command.meta.description or "Run the Wasinix ${name} command";};
  }) (commands // {default = commands.wasinix;});
}
