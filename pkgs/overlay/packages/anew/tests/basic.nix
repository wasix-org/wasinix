{
  wasmerPkgs,
  testLib,
  ...
}: {
  append = testLib.mkWasixRun {
    name = "anew-append";
    wasixPkgs = [wasmerPkgs.anew];
    script = ''
      values="$WASIX_TEST_ROOT/values"
      printf 'one\ntwo\n' > "$values"
      output=$(printf 'two\nthree\n' | anew "$values")
      [ "$output" = "three" ]
      [ "$(cat "$values")" = $'one\ntwo\nthree' ]
    '';
  };
}
