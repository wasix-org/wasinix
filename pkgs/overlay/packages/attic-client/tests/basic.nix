{
  testLib,
  wasmerPkgs,
  ...
}: {
  version = testLib.mkWasixRun {
    name = "attic-client-version";
    wasixPkgs = [wasmerPkgs.attic-client];
    script = "attic --version";
  };
}
