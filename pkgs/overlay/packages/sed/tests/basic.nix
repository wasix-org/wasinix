{
  pkgs,
  wasmerPkgs,
  testLib,
  ...
}: let
  nativeSed = [pkgs.gnused];
  wasixSed = [wasmerPkgs.sed];
in {
  version = testLib.mkWasixRun {
    name = "sed-version";
    wasixPkgs = wasixSed;
    script = "sed --version";
  };

  substitute = testLib.mkScriptComparison {
    name = "sed-substitute";
    nativePkgs = nativeSed;
    wasixPkgs = wasixSed;
    script = ''
      echo "hello world" | sed 's/world/there/'
    '';
  };

  delete = testLib.mkScriptComparison {
    name = "sed-delete";
    nativePkgs = nativeSed;
    wasixPkgs = wasixSed;
    script = ''
      printf 'keep\ndelete me\nkeep\n' | sed '/delete/d'
    '';
  };

  print = testLib.mkScriptComparison {
    name = "sed-print";
    nativePkgs = nativeSed;
    wasixPkgs = wasixSed;
    script = ''
      printf 'foo\nbar\nbaz\n' | sed -n '/bar/p'
    '';
  };

  address-range = testLib.mkScriptComparison {
    name = "sed-address-range";
    nativePkgs = nativeSed;
    wasixPkgs = wasixSed;
    script = ''
      printf 'a\nb\nc\nd\ne\n' | sed '2,4d'
    '';
  };

  inplace = testLib.mkScriptComparison {
    name = "sed-inplace";
    nativePkgs = nativeSed;
    wasixPkgs = wasixSed;
    script = ''
      echo "hello world" > test.txt
      sed -i 's/world/there/' test.txt
      cat test.txt
    '';
  };

  multiple-expressions = testLib.mkScriptComparison {
    name = "sed-multiple-expressions";
    nativePkgs = nativeSed;
    wasixPkgs = wasixSed;
    script = ''
      echo "foo bar baz" | sed -e 's/foo/FOO/' -e 's/bar/BAR/'
    '';
  };
}
