{
  entry,
  pkgs,
  ...
}: let
  padding = builtins.concatStringsSep "" (builtins.genList (_: " ") 140000);
  selector = pkgs.writeText "nix-eval-jobs-selection.nix" ''
    ${padding}
    jobs: let names = builtins.fromJSON "[\"tests.packages.requests.versions.\\\"2.32.3\\\".behavior\"]"; in builtins.listToAttrs (map (name: { inherit name; value = jobs.''${name}; }) names)
  '';
in {
  quoted-address =
    pkgs.runCommand "nix-eval-jobs-quoted-address-check" {
      nativeBuildInputs = [entry.package pkgs.python3 pkgs.writableTmpDirAsHomeHook];
    } ''
      nix-eval-jobs --expr --no-instantiate --workers 1 \
        --select-file ${selector} \
        '{ "tests.packages.requests.versions.\"2.32.3\".behavior" = derivation { name = "probe"; system = builtins.currentSystem; builder = ":"; }; ignored = derivation { name = "ignored"; system = builtins.currentSystem; builder = ":"; }; }' \
        > jobs.jsonl
      python3 - <<'PY'
      import json

      [job] = [json.loads(line) for line in open("jobs.jsonl")]
      address = 'tests.packages.requests.versions."2.32.3".behavior'
      assert job["attrPath"] == [address], job
      assert job["attr"] == json.dumps(address), job
      assert "error" not in job, job
      PY
      touch "$out"
    '';
}
