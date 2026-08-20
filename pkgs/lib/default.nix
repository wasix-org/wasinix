# Helpers for wasix package files, and the optional passthru.wasix declaration:
# supportedProfiles, preferredProfile, ciProfiles, ciTags, shipped, broken,
# retention, retentionHook, postUpdateHook (old/new version arguments),
# emulatedCheck, updateNotes (docs/packaging.md, docs/updating.md).
# applyWasixMeta below is the only writer of meta.badPlatforms/meta.broken.
{
  lib,
  referenceScanner ? null,
  snapshotZstd ? null,
}: let
  profilesCfg = import ../profiles.nix;
  # extendDrv hands the filters below `null` for an attr the package never set.
  orEmpty = xs:
    if xs == null
    then []
    else xs;
in rec {
  mergeScript = frags: lib.concatStringsSep "\n" (lib.filter (f: f != "" && f != null) frags);

  # Exact match, unlike dropInputsByNameInfix. Nulls (nixpkgs' disabled optional
  # deps) go with the named inputs, since getName cannot read them.
  dropInputsByName = names: xs:
    builtins.filter (x: x != null && !(builtins.elem (lib.getName x) names)) (orEmpty xs);

  # Substring match.
  dropInputsByNameInfix = names: xs:
    builtins.filter (x: x != null && !(lib.any (n: lib.hasInfix n (lib.getName x)) names)) (orEmpty xs);

  # Swap inputs by name, for a release that caps a sibling the set has moved
  # past and so takes that sibling's history entry. Nulls pass through, since
  # getName cannot read them.
  replaceInputsByName = swaps: xs:
    map (x:
      if x == null
      then x
      else swaps.${lib.getName x} or x) (orEmpty xs);

  # The static cross layer mirrors buildInputs into propagatedBuildInputs (a static
  # archive records no link deps), so an input filter has to cover both.
  linkInputs = f: {
    buildInputs = f;
    propagatedBuildInputs = f;
  };

  # Patches are paths, so they match on the file name.
  dropPatchesByNameInfix = names:
    builtins.filter (p: !(lib.any (n: lib.hasInfix n (baseNameOf (toString p))) names));

  # Build-system flags ("-Dblas=openblas"), matched on their option prefix.
  dropFlagsByPrefix = prefixes: builtins.filter (f: !(lib.any (p: lib.hasPrefix p f) prefixes));

  python = import ./python.nix {inherit lib dropInputsByName dropInputsByNameInfix;};

  loadPackageDir = import ./load-packages.nix {inherit lib;};

  # The `check` output machinery (see check-output.nix).
  checkOutput = import ./check-output.nix {inherit lib referenceScanner snapshotZstd;};

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

  # eh/exnref/pic booleans for a host platform's profile, so a package file
  # tests `(traitsOf hp).eh` instead of `elem (profileOf hp) profiles.withEh`.
  profileTraitsOf = hp: profilesCfg.sysrootEncodings.${profileOf hp};

  wasixMetaOf = drv: (drv.passthru or {}).wasix or {};

  ciTagsOf = drv: let
    tags = (wasixMetaOf drv).ciTags or [];
    invalid =
      builtins.filter (
        tag: !(builtins.isString tag) || builtins.match "[a-z0-9]+(-[a-z0-9]+)*" tag == null
      )
      tags;
  in
    lib.throwIf (!builtins.isList tags)
    "${drv.pname or drv.name}: ciTags must be a list"
    (lib.throwIf (invalid != [])
      "${drv.pname or drv.name}: invalid ciTags; use lowercase kebab-case names"
      (lib.unique tags));

  ciInfoOf = drv: let
    publication = (wasixMetaOf drv).publication or {};
    testExpectation = (wasixMetaOf drv).testExpectation or null;
    changelog = builtins.tryEval (drv.meta.changelog or null);
    version = publication.version or drv.version or null;
    rel = publication.rel or null;
    info =
      lib.optionalAttrs (builtins.isString version) {inherit version;}
      // lib.optionalAttrs (builtins.isInt rel) {inherit rel;}
      // lib.optionalAttrs (changelog.success && builtins.isString changelog.value) {
        changelog = changelog.value;
      }
      // lib.optionalAttrs (builtins.isAttrs testExpectation) {inherit testExpectation;};
    forced = builtins.tryEval (builtins.deepSeq info info);
  in
    if forced.success
    then forced.value
    else {};

  # meta.position ("file:line") as a mkDerivation `pos` argument, so generated
  # drvs inherit their subject's position and `nix edit` lands somewhere useful.
  posOf = drv: let
    p = drv.meta.position or null;
    m =
      if p == null
      then null
      else builtins.match "(.*):([0-9]+)" (toString p);
  in
    if m == null
    then null
    else {
      file = builtins.elemAt m 0;
      line = lib.toInt (builtins.elemAt m 1);
    };

  hasUpdateNotes = drv: let
    r = builtins.tryEval ((wasixMetaOf drv).updateNotes or [] != []);
  in
    r.success && r.value;

  # What an updateNote's predicate compares. A package pinned by a flake input
  # keeps upstream's version across rev bumps, hence the noteVersion escape.
  noteVersionOf = drv: (wasixMetaOf drv).noteVersion or drv.version or null;

  # updateNotes whose predicate fires for (prior, current).
  firedNotesOf = prior: drv: let
    version = noteVersionOf drv;
    defaultWhen = p: c: p != null && p != c;
    fired =
      map (
        n:
          {
            inherit (n) message;
            inherit prior version;
          }
          // lib.optionalAttrs (n ? name) {inherit (n) name;}
      )
      (lib.filter (n: (n.when or defaultWhen) prior version)
        ((wasixMetaOf drv).updateNotes or []));
    forced = builtins.tryEval (builtins.deepSeq fired fired);
  in
    if forced.success
    then forced.value
    else [];

  # Reads passthru, not meta, so the answer is unchanged by applyWasixMeta.
  supportedIn = profileName: drv:
    builtins.elem profileName ((wasixMetaOf drv).supportedProfiles or profiles.all);

  shippedOf = drv: (wasixMetaOf drv).shipped or false;

  preferredProfileOf = drv: let
    w = wasixMetaOf drv;
    supported = w.supportedProfiles or profiles.all;
    preferred =
      if w ? preferredProfile
      then w.preferredProfile
      else if builtins.elem defaultProfileName supported
      then defaultProfileName
      else builtins.head supported;
  in
    lib.throwIf (!(builtins.elem preferred supported))
    "${drv.pname or drv.name}: preferredProfile '${preferred}' is not in supportedProfiles"
    preferred;

  # CI coverage is independent of platform support. Shipped products already
  # have a canonical build through wasmerPackages, while an explicit preference
  # likewise opts into one canonical profile unless ciProfiles says otherwise.
  ciProfilesOf = drv: let
    w = wasixMetaOf drv;
    supported = w.supportedProfiles or profiles.all;
    selected =
      w.ciProfiles
      or (
        if w ? preferredProfile || shippedOf drv
        then [(preferredProfileOf drv)]
        else supported
      );
    invalid = builtins.filter (profile: !(builtins.elem profile supported)) selected;
  in
    lib.throwIf (invalid != [])
    "${drv.pname or drv.name}: ciProfiles contains unsupported profile(s): ${lib.concatStringsSep ", " invalid}"
    selected;

  # Applied to every package by the overlay loader. All profiles share one system
  # string, so badPlatforms is only meaningful within the setting profile's set.
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

  # Merge by kind: functions get the old value, phases concatenate, lists append,
  # attrsets merge recursively, everything else replaces.
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

  # Apply tweaks (merged per extendDrv). The cross gate keeps the phase out of
  # the shipped build; emulated-check.nix un-gates declared suites separately.
  libTweaks = tweaks: pkg:
    pkg.overrideAttrs (old: let
      disablesCheckSnapshot =
        (old.wasixCheckIsCSuite or false)
        && tweaks ? doCheck
        && !tweaks.doCheck;
      effectiveTweaks =
        tweaks
        // lib.optionalAttrs disablesCheckSnapshot {
          wasixCheckSnapshotPhase = _: ''
            if [ -n "''${check:-}" ]; then
              echo "checks are disabled on this derivation; skipping the test snapshot"
              mkdir -p "$check"
            fi
          '';
        };
      merged = extendDrv old effectiveTweaks;
      # Rewriting the source or the build changes what the wheel contains, so
      # PyPI's copy of this version is not a substitute and the registry has to
      # serve ours (pkgs/python-registry). Skipping a test does not.
      supersedesPyPI = lib.any (a: effectiveTweaks ? ${a}) [
        "src"
        "version"
        "pname"
        "patches"
        "prePatch"
        "postPatch"
        "preBuild"
        "postBuild"
      ];
    in
      merged
      # buildPythonPackage derives passthru.requiredPythonModules when it is
      # called, and overrideAttrs runs after that, so a python dependency added
      # here is otherwise missing from the closure the wheel tests and the
      # registry walk read. extendDrv answers only for the attrs tweaks names,
      # so the inputs come from the same old // new the override itself applies.
      // lib.optionalAttrs (pkg ? pythonModule) {
        passthru =
          (old.passthru or {})
          // (merged.passthru or {})
          // {
            requiredPythonModules =
              pkg.pythonModule.pkgs.requiredPythonModules
              ((old // merged).propagatedBuildInputs or []);
            wasix =
              (old.passthru.wasix or {})
              // (merged.passthru.wasix or {})
              // lib.optionalAttrs supersedesPyPI {inherit supersedesPyPI;};
          };
      });

  # The webc packaging derives one command per bin/*.wasm. posixAlias also keeps
  # the unsuffixed name as a symlink, for consumers that exec it by store path
  # (git's shell subcommands run ${gnused}/bin/sed).
  wasmRename = {
    wasmName,
    posixAlias ? false,
  }: pkg:
    pkg.overrideAttrs (old: {
      # Indented strings drop their leading newline, so `+` would glue onto
      # old.postInstall. bin/ is usually in $out but can be in $bin (curl).
      postInstall = mergeScript [
        (old.postInstall or "")
        ''
          for _bindir in "$out" ''${bin:+"$bin"}; do
            if [ -f "$_bindir/bin/${wasmName}" ]; then
              mv "$_bindir/bin/${wasmName}" "$_bindir/bin/${wasmName}.wasm"
              for _link in "$_bindir/bin/"*; do
                if [ -L "$_link" ] && [ "$(basename "$(readlink "$_link")")" = "${wasmName}" ]; then
                  ln -sf "${wasmName}.wasm" "$_link"
                fi
              done
              ${lib.optionalString posixAlias ''ln -s "${wasmName}.wasm" "$_bindir/bin/${wasmName}"''}
            fi
          done
        ''
      ];
    });
}
