# Rebuild selected WASIX packages from the working tree while every package
# below them remains pinned to a pristine revision. The result mixes objects
# from two toolchains and is evidence for an experiment, not a release build.
{
  base,
  targets,
  keep ? null,
  system ? "x86_64-linux",
  root ? toString ./.,
}: let
  flakeAt = ref: builtins.getFlake "git+file://${root}${ref}";
  workFlake = flakeAt "";
  baseProject = (flakeAt "?rev=${base}").legacyPackages.${system};
  inherit (workFlake.inputs.nixpkgs) lib;
  profiles = import ./pkgs/profiles.nix;
  baseByProfile = baseProject.internals.packageSets.wasixRaw;
  toolchainNames = ["stdenv" "rustPlatform" "haskellPackages"];
  packageNames = lib.unique (lib.concatMap builtins.attrNames (builtins.attrValues baseProject.packages.wasix));
  knownNames = packageNames ++ toolchainNames;
  keepNames =
    if keep == null
    then toolchainNames
    else keep;
  unknownKeep = lib.filter (name: !(builtins.elem name knownNames)) keepNames;

  parse = target: let
    path = lib.splitString "." target;
    profile = lib.head path;
    name = lib.last path;
    validProfile = builtins.hasAttr profile baseByProfile;
    validTarget = validProfile && builtins.hasAttr name baseByProfile.${profile};
  in {
    inherit target profile name;
    error =
      if lib.length path != 2
      then "target must be <profile>.<package>, got '${target}'"
      else if !validProfile
      then "unknown profile '${profile}' in '${target}'"
      else if !validTarget
      then "unknown target '${target}'"
      else null;
  };
  parsed = map parse targets;
  errors =
    lib.optional (unknownKeep != []) "unknown keep name(s): ${lib.concatStringsSep ", " unknownKeep}"
    ++ lib.filter (error: error != null) (map (target: target.error) parsed);
  targetNamesFor = profile:
    map (target: target.name) (lib.filter (target: target.profile == profile) parsed);
  unpinnedFor = profile: lib.unique (keepNames ++ targetNamesFor profile);
  pinOverlayFor = profile: final: previous:
    lib.optionalAttrs (previous.stdenv.hostPlatform.isWasix or false)
    (lib.genAttrs
      (lib.filter (name: !(builtins.elem name (unpinnedFor profile))) knownNames)
      (name: baseByProfile.${profile}.${name} or previous.${name}));
  profileForCrossSystem = crossSystem:
    profiles.profileOf {
      wasmExceptions = crossSystem.wasmExceptions or "no";
      wasmPic = crossSystem.wasmPic or false;
    };
  spotProject = workFlake.lib.mkProject {
    inherit system;
    importNixpkgs = args:
      import workFlake.inputs.nixpkgs (
        args
        // {
          overlays =
            (args.overlays or [])
            ++ lib.optionals (args ? crossSystem) [
              (pinOverlayFor (profileForCrossSystem args.crossSystem))
            ];
        }
      );
    ci.sources = ["wasinix"];
  };
  resultFor = target: let
    basePackage = baseByProfile.${target.profile}.${target.name};
    spliced = spotProject.internals.packageSets.wasixRaw.${target.profile}.${target.name};
  in {
    inherit (target) target;
    inherit spliced;
    baseDrv = basePackage;
    changed = spliced.drvPath != basePackage.drvPath;
    mode = "direct";
  };
  results = map resultFor parsed;
in
  if errors != []
  then throw ("spot: " + lib.concatStringsSep "; " errors)
  else {
    spliced = map (result: result.spliced) results;
    baseDrv = map (result: result.baseDrv) results;
    report = {
      inherit base;
      keep = keepNames;
      keptToolchains = lib.filter (name: builtins.elem name keepNames) toolchainNames;
      changed = lib.any (result: result.changed) results;
      targets =
        map (result: {
          inherit (result) target changed mode;
          baseDrvPath = result.baseDrv.drvPath;
          splicedDrvPath = result.spliced.drvPath;
        })
        results;
    };
  }
