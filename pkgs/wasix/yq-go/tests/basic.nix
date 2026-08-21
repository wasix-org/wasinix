{
  pkgs,
  entry,
  harnesses,
  ...
}: {
  yaml-to-json = harnesses.compareShells {
    name = "yq-yaml-to-json";
    hostPackages = [pkgs.yq-go];
    wasixCommands = builtins.attrValues entry.commands;
    script = "printf 'test: 1\\n' | yq eval -M -o=json '.' -";
  };
}
