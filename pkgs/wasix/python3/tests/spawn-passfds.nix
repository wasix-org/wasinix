{
  pkgs,
  harnesses,
  helpers,
  packages,
}: let
  inherit (pkgs) lib;
in
  helpers.forEachPython packages.preferred ({
    pythonCommands,
    pyVer,
    tag,
  }: let
    passfdTest = {
      name,
      fds,
    }:
      harnesses.hostShell {
        name = "python${tag}-${name}";
        wasixCommands = pythonCommands;
        script = ''
          cp ${./spawn-passfd-check.py} check.py
          python${pyVer} check.py ${lib.concatMapStringsSep " " toString fds} | tee out.log
          grep -q PASSFDS_OK out.log
        '';
      };
  in {
    # Below the bounce slots: the fd-passing workaround must deliver the fd.
    passfds-control = passfdTest {
      name = "passfds-control";
      fds = [100];
    };
    # fd at the bounce floor (128): with a fixed slot base this degenerated to
    # the same-fd dup2 wasix ignores, and close(tmp) dropped the fd.
    passfds-at-128 = passfdTest {
      name = "passfds-at-128";
      fds = [128];
    };
    # several fds at 128+: later bounce slots must not clobber fds already
    # placed by earlier bounces.
    passfds-cluster = passfdTest {
      name = "passfds-cluster";
      fds = [129 130];
    };
  })
