{
  testLib,
  wasmerPkgs,
  ...
}: {
  version = testLib.mkWasixRun {
    name = "attic-server-version";
    wasixPkgs = [wasmerPkgs.attic-server];
    script = ''
      atticd --version
      atticadm --version
    '';
  };
}
