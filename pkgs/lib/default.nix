# Helpers for wasix package overlay entries. Because the profile's stdenv
# (replaceCrossStdenv) already builds with wasixcc and auto-threads linked deps,
# these only apply per-package tweaks — no stdenv override, no dep threading.
#
# This is also home to the passthru.wasix support contract. Every wasix package
# may declare (all optional):
#
#   passthru.wasix = {
#     supportedProfiles = profiles.withoutPic;  # profiles it TARGETS (default: all).
#                                               # "Unsupported" = intentionally not
#                                               # targeted — skipped silently, never
#                                               # a CI job. Not a defect.
#     preferredProfile = "off";                 # profile it SHIPS at (default: the
#                                               # repo default if supported, else the
#                                               # first supported profile).
#     broken = "why + link";                    # a DEFECT: should work at its
#                                               # supported profiles but currently
#                                               # doesn't. Visible (meta.broken), with
#                                               # removal pressure once fixed.
#   };
#
# The overlay loader derives nixpkgs meta from it in ONE place (applyWasixMeta),
# and pkgs/default.nix consumes it via supportedIn/preferredProfileOf — nothing
# else hand-writes meta.badPlatforms/meta.broken.
{lib}: let
  profilesCfg = import ../profiles.nix;
in rec {
  # Merge non-empty script fragments.
  mergeScript = frags: lib.concatStringsSep "\n" (lib.filter (f: f != "" && f != null) frags);

  # The profile name (off / eh / ehpic / exnrefEh / exnrefEhpic) for a host
  # platform, from its wasmExceptions/wasmPic fields (see pkgs/profiles.nix).
  inherit (profilesCfg) profileOf defaultProfileName;

  # Profile-set constructors for supportedProfiles declarations.
  profiles = rec {
    table = profilesCfg.profiles;
    all = profilesCfg.profileNames;
    pic = lib.filter (n: table.${n}.wasmPic or false) all;
    withoutPic = lib.filter (n: !(table.${n}.wasmPic or false)) all;
    withEh = lib.filter (n: table.${n}.wasmExceptions != "no") all;
  };

  # The support contract of a derivation (or of an explicit passthru.wasix value).
  wasixMetaOf = drv: (drv.passthru or {}).wasix or {};

  # Does `drv` target this profile? The eval-only predicate behind the library
  # matrix and CI filtering — reads passthru, never meta, so it works the same
  # before and after applyWasixMeta.
  supportedIn = profileName: drv:
    builtins.elem profileName ((wasixMetaOf drv).supportedProfiles or profiles.all);

  # The profile a package ships at: its declared preferredProfile, else the repo
  # default when supported, else the (alphabetically) first supported profile.
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

  # Derive nixpkgs meta from the passthru.wasix contract, for the profile the
  # package set is instantiated at. Applied uniformly by the overlay loader:
  #   - not supported here -> meta.badPlatforms += [hp.system]. All wasix profiles
  #     share one system string, so this only means "unsupported" INSIDE the
  #     profile set that set it — exactly how the matrix/CI predicates read it.
  #     Kept so nixpkgs-native tooling (availableOn etc.) sees it too.
  #   - wasix.broken -> meta.broken (the human-readable reason stays on passthru).
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

  # The standard nixpkgs phases + their pre/post hooks: string attrs that must be CONCATENATED
  # (not replaced) when merged onto a derivation. Used by extendDrv.
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

  # Merge a tweak attrset onto a derivation's `old` attrs, dispatching per-attr by KIND so callers
  # never hand-write `(old.X or []) ++ …` / `(old.X or "") + …` boilerplate:
  #   - a function           -> applied to the old value (the escape for filter/replace/old-dependent)
  #   - a known script phase -> concatenated (mergeScript)
  #   - a list               -> appended to the old list
  #   - an attrset (env/meta/passthru) -> deep-merged recursively, so nested lists append too
  #   - anything else (scalar / derivation / path) -> set
  # Returns the attrs to hand to overrideAttrs.
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

  # Per-package wasix tweaks. Pass any derivation attrs; each is merged onto the package by kind
  # (see extendDrv) — phases concat, lists append, attrsets deep-merge, scalars set, and a function
  # value receives the old value (for filters / replacements). doCheck defaults to false (cross
  # can't run target tests; pass doCheck = true to override). No escape-hatch, no per-attr params.
  libTweaks = tweaks: pkg:
    pkg.overrideAttrs (old: extendDrv old ({doCheck = false;} // tweaks));

  # Rename bin/<wasmName> -> <wasmName>.wasm (the convention allWasm collects),
  # optionally asyncifying. For leaf CLIs.
  wasmRename = {
    wasmName,
    asyncifyFlags ? null,
    binaryen ? null, # only needed when asyncifyFlags != null
  }: pkg:
    pkg.overrideAttrs (old: {
      # mergeScript (not `+`): Nix strips the leading newline of an indented
      # string, so `old + ''<nl>if…''` would glue onto a non-empty old.postInstall
      # with no separator.
      # Rename in whichever output holds bin/ — usually $out, but multi-output
      # packages put it in $bin (e.g. curl's default output is "bin").
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
