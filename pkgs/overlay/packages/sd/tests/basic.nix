{
  pkgs,
  wasmerPkgs,
  testLib,
  ...
}: let
  native = [pkgs.sd];
  wasix = [wasmerPkgs.sd];
  cmp = name: script:
    testLib.mkScriptComparison {
      inherit name script;
      nativePkgs = native;
      wasixPkgs = wasix;
    };
in {
  version = testLib.mkWasixRun {
    name = "sd-version";
    wasixPkgs = wasix;
    script = "sd --version";
  };

  replace = cmp "sd-replace" "printf 'hello world\\n' | sd world rust";
  regex = cmp "sd-regex" "printf 'a1b2c3\\n' | sd '[0-9]' X";
  regex-bs = cmp "sd-regex-bs" "printf 'a1b2c3\\n' | sd '\\d' X";
  capture = cmp "sd-capture" "printf 'foo=bar\\n' | sd '(\\w+)=(\\w+)' '$2=$1'";
}
