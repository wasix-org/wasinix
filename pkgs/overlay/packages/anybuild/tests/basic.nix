{
  testLib,
  wasmerPkgs,
  ...
}: {
  version = testLib.mkWasixRun {
    name = "anybuild-version";
    wasixPkgs = [wasmerPkgs.anybuild];
    script = "anybuild --version";
  };
}
