# Auto-import convention for wasix package sets: a package is <dir>/<name>.nix,
# <dir>/<name>/package.nix, or (if it needs no tweaks) a name in `trivial`.
# A dir's package.nix may also evaluate to {names, packages} instead of a
# function: a multi-package dir (version families like icu). `names` is the
# static attr list it provides; `packages = callArgs: {<name> = drv;}`.
# default.nix and dirs without a package.nix (e.g. shared patches/) are ignored.
# Used by both the top-level overlay and the python packageOverrides, so the
# convention can't drift between sets. `names` is eval-only (no callArgs),
# letting pkgs/default.nix enumerate the set without instantiating one.
{lib}: {
  dir,
  trivial ? [],
  # extra non-package .nix files to skip (e.g. a worklist the set carries).
  exclude ? [],
  # Registry history: mint older versions of a package from one JSON table (not
  # a per-package nix version-family). Shape: {<name> = {<version> = <spec>;};}
  # where <spec> is the args to re-point the package's OWN src fetcher at that
  # version (hash + rev/tag for fetchFromGitHub, version for fetchPypi, url for
  # a fetchurl release tarball), plus optional non-fetch keys: `note`, and
  # `variants` (the set-neutral history gate: the build variants an entry is
  # limited to, read by the set's ship layer -- for wheels a variant is an
  # interpreter; sets with a single variant, like CLIs, ignore it). Each mints
  # a <name>_<version underscored> attr by re-importing <name>'s package file
  # with the base rebased onto that src (via src.override, reusing the real
  # fetcher), so the package's own version conditionals apply, and stamps
  # passthru.wasmer.history. Both package sets use this; the python set passes
  # historyFrom = "pyprev". See docs/packaging.md and the history.json files.
  history ? {},
  # callArgs key holding the set to rebase from: "prev" (top-level overlay) or
  # "pyprev" (python packageOverrides).
  historyFrom ? "prev",
}: let
  historyLib = import ../project/history.nix {inherit lib;};
  inherit (historyLib) historyMeta;
  entries = builtins.readDir dir;
  historyUnder = v: lib.replaceStrings ["."] ["_"] v;
  historyNames = lib.concatLists (lib.mapAttrsToList
    (name: vers: map (v: "${name}_${historyUnder v}") (lib.attrNames vers))
    history);
  fileNames =
    builtins.filter (n: !(builtins.elem n (["default"] ++ exclude)))
    (map (lib.removeSuffix ".nix")
      (lib.attrNames (lib.filterAttrs (n: t: t == "regular" && lib.hasSuffix ".nix" n) entries)));
  dirNames =
    builtins.filter (n: builtins.pathExists (dir + "/${n}/package.nix"))
    (lib.attrNames (lib.filterAttrs (_: t: t == "directory") entries));
  dirEntry = n: import (dir + "/${n}/package.nix");
  isMulti = e: !builtins.isFunction e;
  # A package unit, written either way: <name>.nix or <name>/package.nix. The
  # two are read identically, and either may evaluate to {names, packages}
  # rather than a function; a directory is for a unit that carries files
  # alongside it (patches, a version list), not a different kind of package.
  units =
    map (n: {
      name = n;
      entry = import (dir + "/${n}.nix");
      file = dir + "/${n}.nix";
    })
    fileNames
    ++ map (n: {
      name = n;
      entry = dirEntry n;
      file = dir + "/${n}/package.nix";
    })
    dirNames;
  unitOf = name: lib.findFirst (u: u.name == name) null units;

  # Most packages here override a nixpkgs drv, whose meta.position points into
  # nixpkgs; restamp it to our file so `nix edit`, error messages, and update
  # tooling land where the package is actually defined. Via `pos`, not
  # meta.position: mkDerivation recomputes meta.position from pos after
  # merging attrs.meta, so setting the latter is silently clobbered. meta
  # changes do not move drvPaths.
  stampPosition = file: drv:
    drv.overrideAttrs (_old: {
      pos = {
        file = toString file;
        line = 1;
      };
    });
  pinToHistory = historyLib.rebasePackage;

  # `<set>` with `<set>.<name>` rebased, so a package file that derives from it
  # re-runs its own version conditionals against the older src.
  rebaseHistory = set: name: version: spec:
    set // {${name} = pinToHistory version spec set.${name};};

  # everything this dir declares outright, before history mints anything
  declaredNames =
    lib.concatMap (
      u:
        if isMulti u.entry
        then u.entry.names
        else [u.name]
    )
    units
    ++ trivial;
in {
  names = declaredNames ++ historyNames;

  # Instantiate the set: every package file is a function over one `callArgs`
  # attrset; trivial names go through `mkTrivial`.
  mkPackages = {
    callArgs,
    mkTrivial ? _set: name: throw "load-packages: '${name}' is in the trivial list but no mkTrivial was given",
    # meta.position for the trivial names (the list that declares them)
    trivialPosition ? null,
  }: let
    stampTrivial =
      if trivialPosition != null
      then stampPosition trivialPosition
      else lib.id;
    # (function, file) for a name, however it is written. A trivial name and a
    # name with no file at all are both just the base set, so both rebase the
    # same way as a package file does. A version family is refused: it already
    # is multi-version in nixpkgs.
    sourceOf = name: let
      u = unitOf name;
    in
      if u != null && !(isMulti u.entry)
      then {
        fn = u.entry;
        file = u.file;
      }
      else if u != null
      then throw "load-packages: history for '${name}' is a version family, which nixpkgs already carries at several versions; ship those attrs instead"
      else if builtins.elem name trivial
      then {
        fn = args: mkTrivial args.${historyFrom} name;
        file = trivialPosition;
      }
      else {
        fn = args:
          lib.throwIf (!(args.${historyFrom} ? ${name}))
          "load-packages: history names '${name}', which has no package file here and is not in the base set"
          args.${historyFrom}.${name};
        file = null;
      };
    historyDrv = name: version: spec0: let
      s = sourceOf name;
      spec = historyLib.resolveHistoryLockFile {
        definition =
          if s.file == null
          then null
          else {file = s.file;};
        label = "load-packages: '${name}' ${version}";
        spec = spec0;
      };
      built = s.fn (callArgs // {${historyFrom} = rebaseHistory callArgs.${historyFrom} name version spec;});
      # Rebasing the set only reaches a package file that derives from
      # `${historyFrom}.<name>`. A file that spells its own version and src (a
      # package not in nixpkgs) comes back unchanged, so re-point the result
      # with the same fetcher instead; its own conditionals cannot key on the
      # version, so such a file has to handle both itself.
      rebased =
        if built.version == version
        then built
        else pinToHistory version spec built;
    in
      (
        if s.file == null
        then lib.id
        else stampPosition s.file
      ) (rebased.overrideAttrs (o: {
        passthru =
          (o.passthru or {})
          // {wasmer = (o.passthru.wasmer or {}) // {history = true;};};
      }));
    historyPackages = lib.listToAttrs (lib.concatLists (lib.mapAttrsToList
      (name: vers:
        lib.mapAttrsToList
        (v: spec: lib.nameValuePair "${name}_${historyUnder v}" (historyDrv name v spec))
        vers)
      history));
    # <name>_<version> is exactly how nixpkgs spells its own versioned attrs
    # (openssl_1_1, libsoup_3), and history merges last, so an unlucky entry
    # would silently shadow a real package for every consumer of the set.
    taken =
      lib.filter (n: callArgs.${historyFrom} ? ${n} || builtins.elem n declaredNames)
      historyNames;
  in
    lib.throwIf (taken != [])
    "load-packages: history mints ${lib.concatStringsSep ", " taken}, which already exist(s) in the set; that attr would shadow the existing package"
    ((lib.genAttrs trivial (n: stampTrivial (mkTrivial callArgs.${historyFrom} n)))
      // (builtins.foldl' (
          acc: u:
            acc
            // (
              if isMulti u.entry
              then lib.mapAttrs (_: stampPosition u.file) (u.entry.packages callArgs)
              else {${u.name} = stampPosition u.file (u.entry callArgs);}
            )
        ) {}
        units)
      // historyPackages);
}
