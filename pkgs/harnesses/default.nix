{
  lib,
  makeWasmerPackage,
  pkgs,
  testLib,
  wasmer,
}: let
  validExecutableName = name:
    builtins.isString name
    && name != "."
    && name != ".."
    && baseNameOf name == name;
  commandPackage = command:
    lib.throwIf (!validExecutableName command.name || !validExecutableName command.entrypoint)
    "hostShell command names and entrypoints must be single path components"
    (lib.throwIf (!(command.artifact ? shim))
      "hostShell command '${command.name}' has no executable WebC shim"
      (pkgs.runCommand "wasinix-command-${command.name}" {} ''
        mkdir -p "$out/bin"
        ln -s "$(readlink -e ${command.artifact.shim}/bin/${command.entrypoint})" "$out/bin/${command.entrypoint}"
      ''));
  validateCommand = label: command:
    lib.throwIf (
      !lib.isAttrs command
      || !builtins.isString (command.name or null)
      || !builtins.isString (command.entrypoint or null)
      || !lib.isDerivation (command.artifact.passthru.wasmer.package or null)
    )
    "${label} must be a packaged command"
    command;
  validateFields = label: allowed: value: let
    unknown = lib.subtractLists allowed (lib.attrNames value);
  in
    lib.throwIf (!lib.isAttrs value)
    "${label} must be an attribute set"
    (lib.throwIf (unknown != [])
      "${label} has unknown field(s): ${lib.concatStringsSep ", " unknown}"
      value);
in {
  inherit (testLib) defaultForwardEnv normalizers;

  python = args:
    import ./python.nix ({inherit lib pkgs wasmer;} // args);

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
    grouped = lib.groupBy (command: command.entrypoint) wasixCommands;
    duplicates = lib.attrNames (lib.filterAttrs (_: commands: lib.length commands > 1) grouped);
  in
    lib.throwIf (duplicates != [])
    "hostShell selects duplicate entrypoint(s): ${lib.concatStringsSep ", " duplicates}"
    (testLib.mkWasixRun {
      inherit name script wasmerArgs forwardEnv timeout expectFail broken;
      nativePkgs = hostPackages;
      wasixPkgs = map commandPackage wasixCommands;
    });

  wasixShell = {
    name ? "wasinix-wasix-shell",
    shell,
    commands ? [],
    script,
    host ? {},
    forwardEnv ? testLib.defaultForwardEnv,
    capabilities ? {},
    mounts ? [],
    timeout ? testLib.defaultWasixTimeout,
    expectFail ? null,
    broken ? null,
  }: let
    checkedShell = validateCommand "wasixShell shell" shell;
    checkedCommands = map (validateCommand "wasixShell command") commands;
    checkedHost = validateFields "wasixShell host" ["packages" "setup" "teardown"] host;
    checkedCapabilities = validateFields "wasixShell capabilities" ["network"] capabilities;
    validateMount = mount: let
      checked = validateFields "wasixShell mount" ["source" "target"] mount;
      source = checked.source or null;
      target = checked.target or null;
    in
      lib.throwIf (!(builtins.isPath source || lib.isDerivation source))
      "wasixShell mount source must be a path or derivation"
      (lib.throwIf (
          !builtins.isString target
          || !lib.hasPrefix "/" target
          || target == "/"
          || builtins.elem ".." (lib.splitString "/" target)
        )
        "wasixShell mount target must be an absolute non-root guest path without '..'"
        checked);
    checkedMounts = map validateMount mounts;
    mountTargets = map (mount: mount.target) checkedMounts;
    duplicateMountTargets = lib.attrNames (lib.filterAttrs (_: values: lib.length values > 1) (lib.groupBy (target: target) mountTargets));
    commandNames = map (command: command.name) checkedCommands;
    duplicateCommandNames = lib.attrNames (lib.filterAttrs (_: values: lib.length values > 1) (lib.groupBy (commandName: commandName) commandNames));
    scriptFile = pkgs.writeText "wasinix-wasix-shell.sh" script;
    scriptRoot = pkgs.runCommand "wasinix-wasix-shell-script" {} ''
      mkdir -p "$out"
      cp ${scriptFile} "$out/script.sh"
    '';
    guestSource =
      pkgs.runCommand "wasinix-wasix-shell-package" {
        pname = "wasinix-wasix-shell";
        version = "1.0.0";
        passthru = {
          wasinix.catalog = false;
          wasmer = {
            name = "wasinix-wasix-shell";
            entrypoint = "run";
            dependencies = map (command: command.artifact.passthru.wasmer.package) checkedCommands;
            commands = [
              {
                name = "run";
                dependency = checkedShell.artifact.passthru.wasmer.package;
                dependencyCommand = checkedShell.entrypoint;
                mainArgs = ["/__wasinix_test/script.sh"];
              }
            ];
            fs."/__wasinix_test" = scriptRoot;
          };
        };
      } ''
        mkdir -p "$out"
      '';
    guest = makeWasmerPackage {package = guestSource;};
    wasmerArgs =
      lib.optionals (checkedCapabilities.network or false) ["--net"]
      ++ lib.concatMap (mount: ["--volume" "${mount.source}:${mount.target}"]) checkedMounts;
  in
    lib.throwIf (duplicateCommandNames != [])
    "wasixShell selects duplicate command name(s): ${lib.concatStringsSep ", " duplicateCommandNames}"
    (lib.throwIf (duplicateMountTargets != [])
      "wasixShell selects duplicate mount target(s): ${lib.concatStringsSep ", " duplicateMountTargets}"
      (testLib.mkWasixRun {
        inherit name forwardEnv timeout expectFail broken wasmerArgs;
        script = "run";
        hostSetup = checkedHost.setup or "";
        hostTeardown = checkedHost.teardown or "";
        nativePkgs = checkedHost.packages or [];
        wasixPkgs = [guest.webc.shim];
      }));

  compareShells = {
    name,
    script,
    common ? [],
    hostPackages,
    wasixCommands,
    wasmerArgs ? [],
    forwardEnv ? testLib.defaultForwardEnv,
    timeout ? testLib.defaultTimeout,
    wasixTimeout ? testLib.defaultWasixTimeout,
    normalize ? null,
    expectFail ? null,
    broken ? null,
  }:
    testLib.mkScriptComparison {
      inherit name script common wasmerArgs forwardEnv timeout wasixTimeout normalize expectFail broken;
      nativePkgs = hostPackages;
      wasixPkgs = map commandPackage wasixCommands;
    };
}
