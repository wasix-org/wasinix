{
  entry,
  harnesses,
  ...
}: {
  ca = harnesses.hostShell {
    name = "${entry.name}-ca";
    wasixCommands = builtins.attrValues entry.commands;
    script = ''
      php -r '
        $bundle = "/etc/ssl/certs/ca-bundle.crt";
        if (ini_get("curl.cainfo") !== $bundle || ini_get("openssl.cafile") !== $bundle || !is_file($bundle)) {
            exit(1);
        }
      '
    '';
  };
}
