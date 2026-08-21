{
  pkgs,
  entry,
  harnesses,
  ...
}: let
  native = [pkgs.gnutar];
  wasix = builtins.attrValues entry.commands;
  # Archive bytes carry mtimes/uids that differ; compare the listing and the
  # extracted *content* instead.
  cmp = name: script:
    harnesses.compareShells {
      inherit name script;
      hostPackages = native;
      wasixCommands = wasix;
    };
in {
  version = harnesses.hostShell {
    name = "tar-version";
    wasixCommands = wasix;
    script = "tar --version";
  };

  list = cmp "tar-list" ''
    mkdir d
    touch d/x d/y d/z
    tar -cf out.tar d
    tar -tf out.tar | sort
  '';

  # --no-same-owner: a non-root extract shouldn't restore uid/gid (the wasix
  # chown fails); native tar treats it the same, so the comparison still holds.
  roundtrip = cmp "tar-roundtrip" ''
    mkdir src
    printf 'one\n' > src/a
    printf 'two\n' > src/b
    tar -cf out.tar src
    rm -rf src
    tar --no-same-owner -xf out.tar
    cat src/a src/b
  '';

  subdir-extract = cmp "tar-subdir-extract" ''
    mkdir -p src/nested
    printf 'deep\n' > src/nested/file
    tar -cf out.tar src
    mkdir dst
    tar --no-same-owner -xf out.tar -C dst
    cat dst/src/nested/file
  '';
}
