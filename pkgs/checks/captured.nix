{
  lib,
  emulatedChecks,
}: let
  declaredPhase = package:
    if !(package ? check)
    then null
    else
      (package.overrideAttrs (old: {
        passthru =
          (old.passthru or {})
          // {
            wasinixDeclaredCheckPhase =
              if old.doCheck or false
              then "checkPhase"
              else null;
          };
      }))
      .wasinixDeclaredCheckPhase;
in {
  capturedSuite = {entry, ...}: let
    declared = entry.policy.checks.captured or null;
    spec =
      if declared == null && (entry.policy.shipped or false)
      then null
      else if declared == null
      then {}
      else if declared == false
      then null
      else declared;
    profiles =
      if spec != null && spec ? profiles
      then spec.profiles
      else entry.package.passthru.wasix.supportedProfiles or [entry.variant.profile];
    phase =
      if spec == null
      then null
      else let
        attempted = builtins.tryEval (declaredPhase entry.package);
      in
        if attempted.success
        then attempted.value
        else null;
  in
    lib.optionalAttrs (
      entry.kind
      == "package"
      && entry.scope == "wasix"
      && !(entry.package.meta.broken or false)
      && phase != null
      && builtins.elem entry.variant.profile profiles
    ) {
      tests.captured = emulatedChecks.checkFor {
        drv = entry.package;
        inherit spec phase;
        name = "${entry.name}-${entry.variant.profile}-captured";
      };
    };
}
