# A nested test namespace and an aggregate over all derivation leaves.
{
  pkgs,
  lib,
  posOf,
}: name: tests: let
  flatten = prefix:
    lib.concatMapAttrs (
      testName: value: let
        key =
          if prefix == ""
          then testName
          else "${prefix}-${testName}";
      in
        if testName == "all"
        then throw "test group '${name}' declares the reserved test name '${key}'"
        else if lib.isDerivation value
        then {${key} = value;}
        else if lib.isAttrs value
        then flatten key value
        else throw "test group '${name}' leaf '${key}' is neither a derivation nor an attrset"
    );
  leaves = flatten "" tests;
  ciTags =
    lib.unique
    (lib.concatMap
      (test: ((test.passthru or {}).wasix or {}).ciTags or [])
      (builtins.attrValues leaves));
  firstPos = let
    names = builtins.attrNames leaves;
  in
    if names == []
    then null
    else posOf leaves.${builtins.head names};
  all =
    pkgs.runCommand "test-all-${name}" (
      (lib.optionalAttrs (firstPos != null) {pos = firstPos;})
      // {
        __structuredAttrs = true;
        wasixTestDependencies = builtins.attrValues leaves;
        passthru.wasix =
          {testCases = leaves;}
          // lib.optionalAttrs (ciTags != []) {inherit ciTags;};
      }
    ) ''
      ${lib.concatMapStringsSep "\n" (n: "test -e ${leaves.${n}}") (builtins.attrNames leaves)}
      touch $out
    '';
in
  all // tests // {inherit all;}
