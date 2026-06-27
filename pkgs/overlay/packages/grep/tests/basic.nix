{
  pkgs,
  wasmerPkgs,
  testLib,
  ...
}: let
  native = [pkgs.gnugrep];
  wasix = [wasmerPkgs.grep];
  cmp = name: script:
    testLib.mkScriptComparison {
      inherit name script;
      nativePkgs = native;
      wasixPkgs = wasix;
    };
in {
  # Version banners differ; just assert it runs.
  version = testLib.mkWasixRun {
    name = "grep-version";
    wasixPkgs = wasix;
    script = "grep --version";
  };

  match = cmp "grep-match" "printf 'apple\\nbanana\\ncherry\\n' | grep an";
  count = cmp "grep-count" "printf 'a\\nab\\nabc\\n' | grep -c a";
  invert = cmp "grep-invert" "printf 'keep\\ndrop\\nkeep\\n' | grep -v drop";
  ignore-case = cmp "grep-ignore-case" "printf 'Foo\\nFOO\\nbar\\n' | grep -ic foo";
  line-number = cmp "grep-line-number" "printf 'x\\ny\\nx\\n' | grep -n x";
  extended = cmp "grep-extended" "printf 'a1\\nbb\\nc3\\n' | grep -E '[0-9]'";
  # -P exercises the PCRE backend (final.pcre2); \d is perl-only.
  perl-regexp = cmp "grep-perl-regexp" "printf 'foo123\\nbar\\nbaz456\\n' | grep -oP '\\d+'";
  fixed = cmp "grep-fixed" "printf 'a.b\\naxb\\n' | grep -F 'a.b'";
  only-matching = cmp "grep-only-matching" "printf 'foo=1 bar=2\\n' | grep -oE '[a-z]+=[0-9]'";

  recursive = cmp "grep-recursive" ''
    mkdir -p tree/sub
    printf 'hit\n' > tree/a.txt
    printf 'miss\n' > tree/sub/b.txt
    printf 'hit\n' > tree/sub/c.txt
    grep -rl hit tree | sort
  '';
}
