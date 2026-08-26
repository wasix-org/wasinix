{
  commands,
  entry,
  harnesses,
  ...
}: {
  append = harnesses.wasixShell {
    name = "anew-append";
    shell = commands.bash;
    commands = builtins.attrValues entry.commands ++ [commands.cat];
    script = ''
      values="$WASIX_TEST_ROOT/values"
      printf 'one\ntwo\n' > "$values"
      output=$(printf 'two\nthree\n' | anew "$values")
      [ "$output" = "three" ]
      [ "$(cat "$values")" = $'one\ntwo\nthree' ]
    '';
  };
}
