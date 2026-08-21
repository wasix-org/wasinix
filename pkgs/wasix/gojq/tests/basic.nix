{
  pkgs,
  entry,
  harnesses,
  ...
}: {
  query = harnesses.compareShells {
    name = "gojq-query";
    hostPackages = [pkgs.gojq];
    wasixCommands = builtins.attrValues entry.commands;
    script = ''
      printf '%s\n' '{"values":["hello","world"]}' | gojq --raw-output '.values[1]'
    '';
  };
}
