{
  makeWasmerPackage,
  git,
  cacert,
}:
makeWasmerPackage {
  package = git;
  name = "git";
  owner = "kilyanni";
  inherit (git) version;
  description = "Distributed version control system";
  license = "GPL-2.0-only";
  fs = {
    "/etc/ssl" = "${cacert}/etc/ssl";
    # SHELL_PATH baked into the binary points at sh.wasm in the nix store.
    # Mount the whole sh derivation at its store path so the baked-in path
    # resolves on consumer machines. (wasmer [fs] doesn't mount individual
    # files — only directories — hence mounting the dir, not the .wasm.)
    # Same story for the git derivation: GIT_EXEC_PATH points into its
    # libexec/git-core, mounted here so helpers resolve.
    # Dep flows through the value; the key is just text in wasmer.toml.
    ${builtins.unsafeDiscardStringContext (toString git.sh)} = git.sh;
    ${builtins.unsafeDiscardStringContext (toString git)} = git;
  };
  commands = [
    {
      name = "git";
      module = "git";
      wasm = "git.wasm";
      output = "git.wasm";
      env = {
        SSL_CERT_FILE = "/etc/ssl/certs/ca-bundle.crt";
        GIT_SSL_CAINFO = "/etc/ssl/certs/ca-bundle.crt";
      };
    }
  ];
}
