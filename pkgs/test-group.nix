# A test group: a derivation that builds all the given tests (each a separate
# derivation, so they still build in parallel) and carries each as a sub-attr —
# so `group` runs everything and `group.<name>` runs just one. Used for both the
# behavioural (webc) suites and the toolchain (link/stdenv/sysroot) suites, so
# every package's tests have the same shape.
{
  pkgs,
  lib,
}: name: tests: let
  # Depend on each subtest (referencing its path forces it to build) without
  # reading it — `test -e` works whether the output is a file or a directory.
  all = pkgs.runCommand "test-all-${name}" {} ''
    ${lib.concatMapStringsSep "\n" (n: "test -e ${tests.${n}}") (builtins.attrNames tests)}
    touch $out
  '';
in
  all // tests // {inherit all;}
