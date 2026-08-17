{
  pkgs,
  wasmerPkgs,
  testLib,
  ...
}: {
  query = testLib.mkScriptComparison {
    name = "gojq-query";
    nativePkgs = [pkgs.gojq];
    wasixPkgs = [wasmerPkgs.gojq];
    script = ''
      printf '%s\n' '{"values":["hello","world"]}' | gojq --raw-output '.values[1]'
    '';
  };
}
