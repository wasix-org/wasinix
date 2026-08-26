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
  validateCommand = harness: command:
    lib.throwIf (!validExecutableName command.name || !validExecutableName command.entrypoint)
    "${harness} command names and entrypoints must be single path components"
    (lib.throwIf (!(command.artifact ? shim))
      "${harness} command '${command.name}' has no executable WebC shim"
      command);
  commandPackage = harness: command: let
    checked = validateCommand harness command;
  in
    pkgs.runCommand "wasinix-command-${checked.name}" {} ''
      mkdir -p "$out/bin"
      ln -s "$(readlink -e ${checked.artifact.shim}/bin/${checked.entrypoint})" "$out/bin/${checked.entrypoint}"
    '';
  validateCommands = harness: commands: let
    checked = map (validateCommand harness) commands;
    grouped = lib.groupBy (command: command.entrypoint) checked;
    duplicates = lib.attrNames (lib.filterAttrs (_: values: lib.length values > 1) grouped);
  in
    lib.throwIf (duplicates != [])
    "${harness} selects duplicate entrypoint(s): ${lib.concatStringsSep ", " duplicates}"
    checked;
  validateFields = label: allowed: value: let
    unknown = lib.filter (field: !(builtins.elem field allowed)) (lib.attrNames value);
  in
    lib.throwIf (unknown != [])
    "${label} has unknown field(s): ${lib.concatStringsSep ", " unknown}"
    value;
  runtimeFlags = runtime: let
    checked = validateFields "wasixShell runtime" ["network" "threads"] runtime;
    bool = field:
      lib.throwIf (!builtins.isBool (checked.${field} or false))
      "wasixShell runtime.${field} must be a boolean"
      (checked.${field} or false);
  in
    lib.optionals (bool "network") ["--net"]
    ++ lib.optionals (bool "threads") ["--enable-threads"];
  commandSourcePackage = command:
    lib.throwIf (!(command ? package) || !lib.isDerivation command.package)
    "wasixShell command '${command.name}' has no source package"
    command.package;
  withDependencies = package: dependencies:
    package.overrideAttrs (old: {
      passthru =
        (old.passthru or {})
        // {
          wasmer =
            ((old.passthru or {}).wasmer or {})
            // {
              dependencies =
                (((old.passthru or {}).wasmer or {}).dependencies or [])
                ++ dependencies;
            };
        };
    });
  hostScript = {
    guestScript,
    setup,
    shell,
    teardown,
  }:
    pkgs.writeShellScript "wasinix-wasix-shell-host.sh" ''
      cleanup() {
        status=$?
        trap - EXIT INT TERM
        set +e
        ${teardown}
        teardown_status=$?
        if [ "$status" -eq 0 ]; then
          status=$teardown_status
        fi
        exit "$status"
      }
      trap cleanup EXIT
      trap 'exit 130' INT
      trap 'exit 143' TERM

      ${setup}
      cp ${guestScript} "$WASIX_TEST_ROOT/script.sh"
      ${lib.escapeShellArg shell} "$WASIX_TEST_ROOT/script.sh"
    '';
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
    commands = validateCommands "hostShell" wasixCommands;
  in
    testLib.mkWasixRun {
      inherit name script wasmerArgs forwardEnv timeout expectFail broken;
      nativePkgs = hostPackages;
      wasixPkgs = map (commandPackage "hostShell") commands;
    };

  wasixShell = {
    name ? "wasinix-wasix-shell",
    shell,
    script,
    commands ? [],
    runtime ? {},
    host ? {},
    forwardEnv ? testLib.defaultForwardEnv,
    timeout ? testLib.defaultWasixTimeout,
    expectFail ? null,
    broken ? null,
  }: let
    checkedShell = validateCommand "wasixShell shell" shell;
    checkedCommands = validateCommands "wasixShell" commands;
    checkedHost = validateFields "wasixShell host" ["packages" "setup" "teardown"] host;
    dependencies = map commandSourcePackage checkedCommands;
    shellPackage = withDependencies (commandSourcePackage checkedShell) dependencies;
    artifact = (makeWasmerPackage {package = shellPackage;}).webc;
    guestScript = pkgs.writeText "${name}.sh" script;
    runner = commandPackage "wasixShell shell" (checkedShell // {inherit artifact;});
  in
    testLib.mkWasixRun {
      inherit name forwardEnv timeout expectFail broken;
      nativePkgs = checkedHost.packages or [];
      wasixPkgs = [runner];
      wasmerArgs = runtimeFlags runtime;
      script = hostScript {
        inherit guestScript;
        shell = checkedShell.entrypoint;
        setup = checkedHost.setup or "";
        teardown = checkedHost.teardown or "";
      };
    };

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
      wasixPkgs = map (commandPackage "compareShells") (validateCommands "compareShells" wasixCommands);
    };
}
