# A derivation that depends on all given tests (each still a separate
# derivation, so they build in parallel) and carries each as a sub-attr:
# `group` runs everything, `group.<name>` runs one. Shared by the behavioural
# (webc) and toolchain (link/stdenv/sysroot) suites.
{
  pkgs,
  lib,
  posOf,
}: name: tests: let
  # Direct aggregate builds need every capability used by their members.
  ciTags =
    lib.unique
    (lib.concatMap
      (test: ((test.passthru or {}).wasix or {}).ciTags or [])
      (builtins.attrValues tests));
  # The aggregate carries the first test's position for direct `nix edit` use.
  firstPos = let
    names = builtins.attrNames tests;
  in
    if names == []
    then null
    else posOf tests.${builtins.head names};
  # Referencing each subtest's path forces it to build; `test -e` works whether
  # the output is a file or a directory.
  all =
    pkgs.runCommand "test-all-${name}" (
      lib.optionalAttrs (firstPos != null) {pos = firstPos;}
      // {
        passthru.wasix =
          {testCases = tests;}
          // lib.optionalAttrs (ciTags != []) {inherit ciTags;};
      }
    ) ''
      ${lib.concatMapStringsSep "\n" (n: "test -e ${tests.${n}}") (builtins.attrNames tests)}
      touch $out
    '';
in
  all // tests // {inherit all;}
