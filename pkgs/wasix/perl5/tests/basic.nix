# perl under wasmer. The XS case is the reason this build is PIC-only: the
# module is a side module reached through dlopen, not linked into perl.
{
  harnesses,
  entry,
  packages,
  ...
}: let
  wasix = builtins.attrValues entry.commands;
  run = name: script:
    harnesses.hostShell {
      name = "perl-${name}";
      wasixCommands = wasix;
      inherit script;
    };
in {
  module-upstream = harnesses.capturedSuite {
    drv = packages.sameProfile.perlPackages.SubIdentify;
  };

  version = run "version" "perl -v";

  print = run "print" ''
    out=$(perl -e 'print "ok\n"')
    [ "$out" = ok ]
  '';

  # perl leaves through longjmp, so a wrong exit status means the jump escaped
  # rather than reaching perl's own handler.
  exit-status = run "exit-status" ''
    perl -e 'exit 0'
    rc=0; perl -e 'exit 3' || rc=$?
    [ "$rc" = 3 ]
    rc=0; perl -e 'die "boom\n"' 2>/dev/null || rc=$?
    [ "$rc" = 255 ]
  '';

  xs-module = run "xs-module" ''
    out=$(perl -MData::Dumper -e '$Data::Dumper::Indent=0; print Dumper([1,2])')
    [ "$out" = "\$VAR1 = [1,2];" ]
  '';
}
