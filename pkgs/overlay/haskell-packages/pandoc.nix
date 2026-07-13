# wasm has no sockets; drop pandoc's HTTP/TLS stack (openURL is stubbed to error).
{
  hprev,
  toolchain,
  ...
}:
toolchain.haskell.lib.overrideCabal hprev.pandoc (old: {
  patches = (old.patches or []) ++ [./patches/pandoc/wasi-drop-network.patch];
  libraryHaskellDepends =
    (import ./lib/deps.nix).dropDeps [
      "http-client"
      "http-client-tls"
      "network"
      "tls"
      "crypton-connection"
      "crypton-x509-system"
    ]
    old.libraryHaskellDepends;
})
