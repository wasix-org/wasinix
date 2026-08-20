# The CLI under wasmer, against the native openssl of the same version. The
# forking OCSP responder is the one app feature wasi cannot have (HAVE_FORK=0).
{
  pkgs,
  testLib,
  crossPkgs,
  makeWasmerPackage,
  ...
}: let
  wasix = [(makeWasmerPackage {package = crossPkgs.openssl.bin;}).shim];
  cmp = name: script:
    testLib.mkScriptComparison {
      name = "openssl-${name}";
      nativePkgs = [pkgs.openssl];
      wasixPkgs = wasix;
      inherit script;
    };
in {
  version = testLib.mkWasixRun {
    name = "openssl-version";
    wasixPkgs = wasix;
    script = "openssl version";
  };

  digest = cmp "digest" "printf 'hello' | openssl dgst -sha256";
  base64 = cmp "base64" "printf 'wasix' | openssl base64";
  rand-hex = cmp "rand-hex" "openssl rand -hex 8 | wc -c";
  ciphers = cmp "ciphers" "openssl ciphers -v | head -3 | awk '{print \$1}'";
}
