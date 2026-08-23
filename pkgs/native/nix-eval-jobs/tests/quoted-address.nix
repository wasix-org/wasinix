{
  entry,
  pkgs,
  ...
}: {
  quoted-address =
    pkgs.runCommand "nix-eval-jobs-quoted-address-check" {
      nativeBuildInputs = [entry.package pkgs.python3 pkgs.writableTmpDirAsHomeHook];
    } ''
      nix-eval-jobs --expr --no-instantiate --workers 1 \
        '{ "tests.packages.requests.versions.\"2.32.3\".behavior" = derivation { name = "probe"; system = builtins.currentSystem; builder = ":"; }; }' \
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
