{
  pkgs,
  entry,
  harnesses,
  ...
}: let
  native = [pkgs.jq];
  wasix = builtins.attrValues entry.commands;
  cmp = name: script:
    harnesses.compareShells {
      inherit name script;
      hostPackages = native;
      wasixCommands = wasix;
      # Under wasmer jq sees stdout as a TTY (isatty returns true even when it's
      # redirected to a file) and ANSI-colorizes output; native (piped) doesn't.
      # Strip ANSI so the comparison is on content, not the TTY-detection quirk.
      normalize = harnesses.normalizers.stripAnsi;
    };
in {
  version = harnesses.hostShell {
    name = "jq-version";
    wasixCommands = wasix;
    script = "jq --version";
  };

  field = cmp "jq-field" "echo '{\"a\":1,\"b\":2}' | jq '.a'";
  add = cmp "jq-add" "echo '[1,2,3,4]' | jq 'add'";
  length = cmp "jq-length" "echo '{\"x\":[1,2,3]}' | jq '.x | length'";
  pipe = cmp "jq-pipe" "echo '\"hello\"' | jq 'ascii_upcase'";
  map-select = cmp "jq-map-select" "echo '[1,2,3,4,5]' | jq 'map(select(. % 2 == 0))'";
  # exercises the oniguruma regex backend
  regex = cmp "jq-regex" "echo '\"foo123bar456\"' | jq '[match(\"[0-9]+\"; \"g\").string]'";
}
