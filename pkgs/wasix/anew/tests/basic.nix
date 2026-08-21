{
  entry,
  harnesses,
  ...
}: {
  append = harnesses.hostShell {
    name = "anew-append";
    wasixCommands = builtins.attrValues entry.commands;
    script = ''
      values="$WASIX_TEST_ROOT/values"
      printf 'one\ntwo\n' > "$values"
      output=$(printf 'two\nthree\n' | anew "$values")
      [ "$output" = "three" ]
      [ "$(cat "$values")" = $'one\ntwo\nthree' ]
    '';
  };
}
