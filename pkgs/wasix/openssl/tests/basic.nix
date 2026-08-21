# The CLI under wasmer, against the native openssl of the same version. The
# forking OCSP responder is the one app feature wasi cannot have (HAVE_FORK=0).
{
  pkgs,
  harnesses,
  entry,
  ...
}: let
  wasix = builtins.attrValues entry.commands;
  cmp = name: script:
    harnesses.compareShells {
      name = "openssl-${name}";
      hostPackages = [pkgs.openssl];
      wasixCommands = wasix;
      inherit script;
    };
in {
  version = harnesses.hostShell {
    name = "openssl-version";
    wasixCommands = wasix;
    script = "openssl version";
  };

  digest = cmp "digest" "printf 'hello' | openssl dgst -sha256";
  base64 = cmp "base64" "printf 'wasix' | openssl base64";
  rand-hex = cmp "rand-hex" "openssl rand -hex 8 | wc -c";
  ciphers = cmp "ciphers" "openssl ciphers -v | head -3 | awk '{print \$1}'";
}
