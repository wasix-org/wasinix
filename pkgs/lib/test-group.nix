# A derivation that depends on all given tests (each still a separate
# derivation, so they build in parallel) and carries each as a sub-attr:
# `group` runs everything, `group.<name>` runs one. Shared by the behavioural
# (webc) and toolchain (link/stdenv/sysroot) suites.
{
  pkgs,
  lib,
}: name: tests: let
  # Referencing each subtest's path forces it to build; `test -e` works whether
  # the output is a file or a directory.
  all = pkgs.runCommand "test-all-${name}" {} ''
    ${lib.concatMapStringsSep "\n" (n: "test -e ${tests.${n}}") (builtins.attrNames tests)}
    touch $out
  '';
in
  all // tests // {inherit all;}
