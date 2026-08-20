{
  lib,
  pkgs,
  testLib,
}: let
  validExecutableName = name:
    builtins.isString name
    && name != "."
    && name != ".."
    && builtins.baseNameOf name == name;
  commandPackage = command:
    lib.throwIf (!validExecutableName command.name || !validExecutableName command.entrypoint)
    "hostShell command names and entrypoints must be single path components"
    (lib.throwIf (!(command.artifact ? shim))
      "hostShell command '${command.name}' has no executable WebC shim"
      (pkgs.runCommand "wasinix-command-${command.name}" {} ''
        mkdir -p "$out/bin"
        ln -s ${command.artifact.shim}/bin/${command.entrypoint} "$out/bin/${command.name}"
      ''));
in {
  hostShell = {
    name ? "wasinix-host-shell",
    script,
    hostPackages ? [],
    wasixCommands ? [],
    wasmerArgs ? [],
    forwardEnv ? testLib.defaultForwardEnv,
    timeout ? testLib.defaultWasixTimeout,
    expectFail ? null,
    broken ? null,
  }: let
    grouped = lib.groupBy (command: command.name) wasixCommands;
    duplicates = lib.attrNames (lib.filterAttrs (_: commands: lib.length commands > 1) grouped);
  in
    lib.throwIf (duplicates != [])
    "hostShell selects duplicate command(s): ${lib.concatStringsSep ", " duplicates}"
    (testLib.mkWasixRun {
      inherit name script wasmerArgs forwardEnv timeout expectFail broken;
      nativePkgs = hostPackages;
      wasixPkgs = map commandPackage wasixCommands;
    });
}
