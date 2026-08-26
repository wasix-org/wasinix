# Rebuild selected WASIX packages from the working tree while every package
# below them remains pinned to a pristine revision. The result mixes objects
# from two toolchains and is evidence for an experiment, not a release build.
{
  base,
  targets,
  sources ? null,
  system ? "x86_64-linux",
  root ? toString ./.,
}: let
  flakeAt = ref: builtins.getFlake "git+file://${root}${ref}";
  workFlake = flakeAt "";
  workProject = workFlake.legacyPackages.${system};
  baseProject = (flakeAt "?rev=${base}").legacyPackages.${system};
  inherit (workFlake.inputs.nixpkgs) lib;
  profiles = import ./pkgs/project/profiles.nix;
  baseNative = baseProject.internals.packageSets.nativeRaw;
  baseByProfile = baseProject.internals.packageSets.wasixRaw;
  nativeNames = builtins.attrNames baseProject.packages.native;
  packageNames = lib.unique (lib.concatMap builtins.attrNames (builtins.attrValues baseByProfile));
  defaultSources = lib.filter (address: builtins.hasAttr address workProject.ci.catalog.packages) workProject.ci.catalog.selectors.groups.toolchain.jobs;
  sourceAddresses =
    if sources == null
    then defaultSources
    else sources;

  sourceFor = address: let
    entry = workProject.catalog.entries.${address} or null;
    supported = entry != null && entry.kind == "package" && entry.instance.kind == "current" && builtins.elem entry.scope ["native" "wasix"];
  in {
    inherit address entry;
    error =
      if entry == null
      then "unknown source package '${address}'"
      else if !supported
      then "source '${address}' is not a current native or WASIX package"
      else null;
  };
  selectedSources = map sourceFor sourceAddresses;
  nativeSourceNames = lib.unique (map (source: source.entry.name) (lib.filter (source: source.error == null && source.entry.scope == "native") selectedSources));
  wasixSourceNamesFor = profile:
    lib.unique (map (source: source.entry.name) (lib.filter (source:
      source.error
      == null
      && source.entry.scope == "wasix"
      && source.entry.variant.profile == profile)
    selectedSources));

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
    lib.filter (error: error != null) (map (source: source.error) selectedSources)
    ++ lib.filter (error: error != null) (map (target: target.error) parsed);
  targetNamesFor = profile:
    map (target: target.name) (lib.filter (target: target.profile == profile) parsed);
  unpinnedFor = profile: lib.unique (wasixSourceNamesFor profile ++ targetNamesFor profile);
  nativePinOverlay = _final: _previous:
    lib.genAttrs
    (lib.filter (name: !(builtins.elem name nativeSourceNames)) nativeNames)
    (name: baseNative.${name});
  pinOverlayFor = profile: _final: previous:
    lib.optionalAttrs (previous.stdenv.hostPlatform.isWasix or false)
    (lib.genAttrs
      (lib.filter (name: !(builtins.elem name (unpinnedFor profile))) packageNames)
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
            ++ [
              (
                if args ? crossSystem
                then pinOverlayFor (profileForCrossSystem args.crossSystem)
                else nativePinOverlay
              )
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
      sources = sourceAddresses;
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
