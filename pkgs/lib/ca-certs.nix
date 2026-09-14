# The CA trust set to mount at /etc/ssl, with the bundle also placed at
# OpenSSL's compiled-in default cert file path. nss-cacert writes only
# /etc/ssl/certs/ca-bundle.crt, but our openssl defaults its cert file to
# /etc/ssl/certs/ca-certificates.crt (ssl.get_default_verify_paths); a consumer
# that does not inherit a command's SSL_CERT_FILE (an anybuild command carries
# only its own env) otherwise lands on that absent default with an empty trust
# store, so every default-context TLS call fails. A copy at the default path
# makes TLS work with no env.
{
  runCommand,
  cacert,
}:
runCommand "wasix-ca-certs" {} ''
  mkdir -p "$out/etc/ssl"
  cp -aL ${cacert}/etc/ssl/. "$out/etc/ssl/"
  chmod -R u+w "$out/etc/ssl"
  cp "$out/etc/ssl/certs/ca-bundle.crt" "$out/etc/ssl/certs/ca-certificates.crt"
''
