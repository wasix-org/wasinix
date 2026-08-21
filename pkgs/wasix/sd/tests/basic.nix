{
  pkgs,
  entry,
  harnesses,
  ...
}: let
  native = [pkgs.sd];
  wasix = builtins.attrValues entry.commands;
  cmp = name: script:
    harnesses.compareShells {
      inherit name script;
      hostPackages = native;
      wasixCommands = wasix;
    };
in {
  version = harnesses.hostShell {
    name = "sd-version";
    wasixCommands = wasix;
    script = "sd --version";
  };

  replace = cmp "sd-replace" "printf 'hello world\\n' | sd world rust";
  regex = cmp "sd-regex" "printf 'a1b2c3\\n' | sd '[0-9]' X";
  regex-bs = cmp "sd-regex-bs" "printf 'a1b2c3\\n' | sd '\\d' X";
  capture = cmp "sd-capture" "printf 'foo=bar\\n' | sd '(\\w+)=(\\w+)' '$2=$1'";
}
