{
  lib,
  linkCheck,
}: {
  packageLink = {
    entry,
    packages,
    ...
  }: let
    declared = entry.policy.checks.link or null;
    spec =
      if declared == true
      then {}
      else declared;
  in
    lib.optionalAttrs (
      entry.kind
      == "package"
      && entry.scope == "wasix"
      && !(entry.package.meta.broken or false)
      && lib.isAttrs spec
    ) {
      tests.link = linkCheck.linkFor packages.sameProfile entry.package spec;
    };
}
