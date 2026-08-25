{
  pkgs,
  entry,
  harnesses,
  ...
}: let
  cmp = name: mode: extra:
    harnesses.compareShells ({
        inherit name;
        hostPackages = [pkgs.unfurl];
        wasixCommands = builtins.attrValues entry.commands;
        script = "printf '%s\\n' 'https://sub.example.com/path?id=1&name=sam' | unfurl ${mode}";
      }
      // extra);
in {
  domains = cmp "unfurl-domains" "domains" {};
  keys = cmp "unfurl-keys" "keys" {
    normalize = pkgs.writeShellScript "normalize-unfurl-keys" ''
      ${pkgs.lib.getExe' pkgs.coreutils "sort"}
    '';
  };
}
