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
  };
  selfMounts = [git.bash git];
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
