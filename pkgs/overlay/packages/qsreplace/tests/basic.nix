{
  pkgs,
  wasmerPkgs,
  testLib,
  ...
}: let
  cmp = name: script:
    testLib.mkScriptComparison {
      inherit name script;
      nativePkgs = [pkgs.qsreplace];
      wasixPkgs = [wasmerPkgs.qsreplace];
    };
in {
  replace = cmp "qsreplace-replace" ''
    printf '%s\n' 'https://example.com/path?one=1&two=2' | qsreplace value
  '';
  append = cmp "qsreplace-append" ''
    printf '%s\n' 'https://example.com/path?one=1&two=2' | qsreplace -a value
  '';
}
