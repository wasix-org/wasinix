# Helpers for wasix package files, and the passthru.wasix declaration (all
# optional): supportedProfiles = profiles the package is built for (default
# all; others skip it silently), preferredProfile = where it ships (default
# exnrefEh, else first supported), broken = "reason" for a real defect.
# applyWasixMeta below is the only writer of meta.badPlatforms/meta.broken.
{lib}: let
  profilesCfg = import ../profiles.nix;
in rec {
  # Merge non-empty script fragments.
  mergeScript = frags: lib.concatStringsSep "\n" (lib.filter (f: f != "" && f != null) frags);

  # Auto-import for package dirs (top-level overlay and python set).
  loadPackageDir = import ./load-packages.nix {inherit lib;};

  # Profile name for a host platform (from wasmExceptions/wasmPic).
  inherit (profilesCfg) profileOf defaultProfileName;

  # Profile subsets for supportedProfiles declarations.
  profiles = rec {
    table = profilesCfg.profiles;
    all = profilesCfg.profileNames;
    pic = lib.filter (n: table.${n}.wasmPic or false) all;
    withoutPic = lib.filter (n: !(table.${n}.wasmPic or false)) all;
    withEh = lib.filter (n: table.${n}.wasmExceptions != "no") all;
  };

  wasixMetaOf = drv: (drv.passthru or {}).wasix or {};

  # Is `drv` built for this profile? Reads passthru, not meta, so the answer
  # is the same before and after applyWasixMeta.
  supportedIn = profileName: drv:
    builtins.elem profileName ((wasixMetaOf drv).supportedProfiles or profiles.all);

  # Declared preferredProfile, else the repo default, else first supported.
  preferredProfileOf = drv: let
    w = wasixMetaOf drv;
    supported = w.supportedProfiles or profiles.all;
  in
    w.preferredProfile
    or (
      if builtins.elem defaultProfileName supported
      then defaultProfileName
      else builtins.head supported
    );

  # passthru.wasix -> meta, applied to every package by the overlay loader:
  # unsupported here -> badPlatforms += [hp.system] (all profiles share one
  # system string, so this is only meaningful within the setting profile set);
  # wasix.broken -> meta.broken = true.
  applyWasixMeta = profileName: hostSystem: drv: let
    w = wasixMetaOf drv;
    unsupported = !(supportedIn profileName drv);
    broken = (w.broken or null) != null;
  in
    if !unsupported && !broken
    then drv
    else
      drv.overrideAttrs (old: {
        meta =
          (old.meta or {})
          // lib.optionalAttrs unsupported {
            badPlatforms = lib.unique (((old.meta or {}).badPlatforms or []) ++ [hostSystem]);
          }
          // lib.optionalAttrs broken {broken = true;};
      });

  # Phases (and hooks) that extendDrv concatenates instead of replacing.
  scriptPhases = [
    "preUnpack"
    "unpackPhase"
    "postUnpack"
    "prePatch"
    "patchPhase"
    "postPatch"
    "preConfigure"
    "configurePhase"
    "postConfigure"
    "preBuild"
    "buildPhase"
    "postBuild"
    "preCheck"
    "checkPhase"
    "postCheck"
    "preInstall"
    "installPhase"
    "postInstall"
    "preFixup"
    "fixupPhase"
    "postFixup"
    "preInstallCheck"
    "installCheckPhase"
    "postInstallCheck"
    "preDist"
    "distPhase"
    "postDist"
  ];

  # Merge tweaks onto old drv attrs by kind, for overrideAttrs: functions get
  # the old value, phases concatenate, lists append, attrsets merge
  # recursively, everything else replaces.
  extendDrv = old: new:
    lib.mapAttrs (
      name: val: let
        cur = old.${name} or null;
      in
        if builtins.isFunction val
        then val cur
        else if builtins.elem name scriptPhases
        then mergeScript [cur val]
        else if builtins.isList val
        then
          (
            if cur == null
            then []
            else cur
          )
          ++ val
        else if lib.isAttrs val && !lib.isDerivation val && lib.isAttrs cur && !lib.isDerivation cur
        then cur // extendDrv cur val
        else val
    )
    new;

  # Apply tweaks (merged per extendDrv). doCheck defaults to false: cross
  # builds can't run target tests.
  libTweaks = tweaks: pkg:
    pkg.overrideAttrs (old: extendDrv old ({doCheck = false;} // tweaks));

  # Rename bin/<wasmName> -> <wasmName>.wasm (what allWasm collects),
  # optionally asyncifying. For shipped CLIs.
  wasmRename = {
    wasmName,
    asyncifyFlags ? null,
    binaryen ? null, # only needed when asyncifyFlags != null
  }: pkg:
    pkg.overrideAttrs (old: {
      # mergeScript, not `+` (indented strings drop their leading newline, so
      # `+` would glue onto old.postInstall). bin/ is usually in $out but can
      # be in $bin (curl).
      postInstall = mergeScript [
        (old.postInstall or "")
        ''
          for _bindir in "$out" ''${bin:+"$bin"}; do
            if [ -f "$_bindir/bin/${wasmName}" ]; then
              mv "$_bindir/bin/${wasmName}" "$_bindir/bin/${wasmName}.wasm"
              ${lib.optionalString (asyncifyFlags != null) ''
              ${binaryen}/bin/wasm-opt --asyncify ${asyncifyFlags} -O2 "$_bindir/bin/${wasmName}.wasm" -o "$_bindir/bin/${wasmName}.wasm"''}
            fi
          done
        ''
      ];
    });
}
