{
  pkgs,
  wasmerPkgs,
  testLib,
  ...
}: {
  yaml-to-json = testLib.mkScriptComparison {
    name = "yq-yaml-to-json";
    nativePkgs = [pkgs.yq-go];
    wasixPkgs = [wasmerPkgs.yq];
    script = "printf 'test: 1\\n' | yq eval -M -o=json '.' -";
  };
}
