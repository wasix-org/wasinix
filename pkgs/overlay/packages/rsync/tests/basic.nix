{
  pkgs,
  wasmerPkgs,
  testLib,
  ...
}: let
  native = [pkgs.rsync];
  wasix = [wasmerPkgs.rsync];
in {
  version = testLib.mkWasixRun {
    name = "rsync-version";
    wasixPkgs = wasix;
    script = "rsync --version";
  };

  sshRemoteShell = testLib.mkWasixRun {
    name = "rsync-ssh-remote-shell";
    wasixPkgs = wasix;
    script = ''
      mkdir home
      HOME="$PWD/home" ssh -G -F /dev/null example.test >config
      grep 'identityfile ~/.ssh/id_rsa' config

      rsync -e 'ssh -V' localhost:/tmp/does-not-exist out 2>err && exit 1
      cat err
      grep 'OpenSSH_' err
    '';
  };

  # Re-enable this as a Wasmer test once rsync local-copy runtime validation is in scope.
  nativeLocalCopy = testLib.mkScriptRun {
    name = "rsync-native-local-copy";
    packages = native;
    script = ''
      mkdir -p src/sub dst
      printf 'hello\n' > src/a.txt
      printf 'nested\n' > src/sub/b.txt
      rsync -r src/ dst/
      find dst -type f -print | sort
      cat dst/a.txt dst/sub/b.txt
    '';
  };
}
