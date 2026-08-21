{
  entry,
  harnesses,
  ...
}: let
  coreutilsCommands = builtins.attrValues entry.commands;
in {
  # Each program is its own webc command on one shared module, so argv[0] is
  # what selects it.
  dispatch = harnesses.hostShell {
    name = "coreutils-dispatch";
    wasixCommands = coreutilsCommands;
    script = ''
      [ "$(basename /a/b/c.txt)" = "c.txt" ]
      [ "$(echo hi)" = "hi" ]
      [ "$(seq 3 | tr '\n' ' ')" = "1 2 3 " ]
      [ "$(printf 'b\na\n' | sort | head -1)" = "a" ]
      echo dispatch-ok
    '';
  };

  # File operations against a real (mapped) directory.
  files = harnesses.hostShell {
    name = "coreutils-files";
    wasixCommands = coreutilsCommands;
    script = ''
      mkdir -p tree/sub
      printf 'one\ntwo\n' > tree/sub/f.txt
      cp tree/sub/f.txt tree/copy.txt
      mv tree/copy.txt tree/moved.txt
      [ "$(wc -l < tree/moved.txt)" = "2" ]
      [ "$(cat tree/sub/f.txt | tail -1)" = "two" ]
      [ "$(ls tree | sort | tr '\n' ' ')" = "moved.txt sub " ]
      [ "$(stat -c %s tree/moved.txt)" = "8" ]
      rm -r tree
      echo files-ok
    '';
  };
}
