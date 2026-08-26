{
  commands,
  pkgs,
  entry,
  harnesses,
  ...
}: let
  nativeSed = [pkgs.gnused];
  wasixSed = builtins.attrValues entry.commands;
in {
  version = harnesses.wasixShell {
    name = "sed-version";
    shell = commands.bash;
    commands = wasixSed;
    script = "sed --version";
  };

  substitute = harnesses.compareShells {
    name = "sed-substitute";
    hostPackages = nativeSed;
    wasixCommands = wasixSed;
    script = ''
      echo "hello world" | sed 's/world/there/'
    '';
  };

  delete = harnesses.compareShells {
    name = "sed-delete";
    hostPackages = nativeSed;
    wasixCommands = wasixSed;
    script = ''
      printf 'keep\ndelete me\nkeep\n' | sed '/delete/d'
    '';
  };

  print = harnesses.compareShells {
    name = "sed-print";
    hostPackages = nativeSed;
    wasixCommands = wasixSed;
    script = ''
      printf 'foo\nbar\nbaz\n' | sed -n '/bar/p'
    '';
  };

  address-range = harnesses.compareShells {
    name = "sed-address-range";
    hostPackages = nativeSed;
    wasixCommands = wasixSed;
    script = ''
      printf 'a\nb\nc\nd\ne\n' | sed '2,4d'
    '';
  };

  inplace = harnesses.compareShells {
    name = "sed-inplace";
    hostPackages = nativeSed;
    wasixCommands = wasixSed;
    script = ''
      echo "hello world" > test.txt
      sed -i 's/world/there/' test.txt
      cat test.txt
    '';
  };

  multiple-expressions = harnesses.compareShells {
    name = "sed-multiple-expressions";
    hostPackages = nativeSed;
    wasixCommands = wasixSed;
    script = ''
      echo "foo bar baz" | sed -e 's/foo/FOO/' -e 's/bar/BAR/'
    '';
  };
}
