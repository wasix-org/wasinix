{exposeWasixExtendedPackage}:
exposeWasixExtendedPackage {
  env = {
    AWS_LC_SYS_NO_JITTER_ENTROPY = "1";
    AWS_LC_SYS_CFLAGS = "-DOPENSSL_NO_TTY";
  };
  # nixpkgs defines the server by overriding attic-client, so drop the
  # client-only exnref conversion; the server installs atticd.wasm.
  postInstall = _: "";
  passthru.wasinix.shipped = true;
  passthru.wasmer = {
    name = "attic-server";
    entrypoint = "atticd";
  };
}
