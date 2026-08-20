# perl under wasmer. The XS case is the reason this build is PIC-only: the
# module is a side module reached through dlopen, not linked into perl.
{
  testLib,
  crossPkgsPic,
  emulatedCheckFor,
  makeWasmerPackage,
  ...
}: let
  wasix = [(makeWasmerPackage {package = crossPkgsPic.perl;}).shim];
  run = name: script:
    testLib.mkWasixRun {
      name = "perl-${name}";
      wasixPkgs = wasix;
      inherit script;
    };
in {
  module-upstream = emulatedCheckFor crossPkgsPic.perlPackages.SubIdentify;

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
