{
  pkgs,
  entry,
  harnesses,
  ...
}: let
  native = [pkgs.gzip];
  wasix = builtins.attrValues entry.commands;
  # Compare the round-trip (decompressed) output, not the compressed bytes;
  # gzip headers carry an OS byte / timestamp that legitimately differ.
  cmp = name: script:
    harnesses.compareShells {
      inherit name script;
      hostPackages = native;
      wasixCommands = wasix;
    };
in {
  version = harnesses.hostShell {
    name = "gzip-version";
    wasixCommands = wasix;
    script = "gzip --version";
  };

  # -f throughout: under wasmer isatty() on a pipe wrongly reports a terminal, so
  # gzip refuses to (de)compress to/from the pipe without --force.
  roundtrip = cmp "gzip-roundtrip" "printf 'hello gzip world\\n' | gzip -cf | gzip -dcf";
  level-9 = cmp "gzip-level-9" "printf 'aaaaaaaaaaaaaaaaaaaa\\n' | gzip -9 -cf | gzip -dcf";
  # gunzip / zcat are gzip + preset webc main-args (-d [-c] -f); the shim runs them
  # via `--entrypoint`, so those args apply.
  gunzip = cmp "gzip-gunzip" "printf 'via gunzip\\n' | gzip -cf | gunzip";
  zcat = cmp "gzip-zcat" "printf 'via zcat\\n' | gzip -cf | zcat";
}
