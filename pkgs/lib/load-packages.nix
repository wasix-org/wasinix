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
  # non-fetch spec keys, stripped before the args go to the src fetcher
  historyMeta = ["note" "variants" "cargoHash" "vendorLayout"];
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
  # A drv re-pointed at a history version, reusing its OWN fetcher:
  # src.override with the spec's fetch args (rev/tag/version + hash). fetchurl
  # release tarballs aren't overridable, so patch the src derivation's url +
  # hash directly (spec carries `url`). Survives the `.override` many package
  # files call (it re-runs the nixpkgs function, which would drop a plain
  # overrideAttrs) by re-pinning the src after each override.
  pinToHistory = version: spec: drv: let
    fetchArgs = builtins.removeAttrs spec historyMeta;
    src =
      if drv.src ? override
      then drv.src.override fetchArgs
      else
        drv.src.overrideAttrs (_: {
          urls = [spec.url];
          outputHash = spec.hash;
          name = baseNameOf spec.url;
        });
    # A rust wheel vendors its crates from the Cargo.lock IN its src, so a
    # rebased src needs a rebased vendor. Two vendor shapes (set/rust-platform.nix):
    # a granular importCargoLock vendor carries `wasixRebuildVendor`, which
    # re-vendors the rebased src's lock directly (per-crate hashes live in the
    # lock, so no stored cargoHash). Where the lock sits differs between the two
    # releases (pydantic-core is its own repo below 2.42, a monorepo directory
    # above), and the entry's vendorLayout says so: correcting it in the package
    # file is too late, since reading the rebuilt vendor's attributes forces the
    # broken one. A monolithic fetchCargoVendor vendor is a
    # runCommand over one re-pointable vendorStaging FOD; nothing derives its
    # hash, so the entry carries it (scripts/history.py TOFUs it).
    rustVendor = old:
      if old.cargoDeps ? wasixRebuildVendor
      then
        old.cargoDeps.wasixRebuildVendor ({
            inherit src;
            cargoHash = spec.cargoHash or null;
          }
          // (spec.vendorLayout or {}))
      else
        lib.throwIf (!(spec ? cargoHash))
        "load-packages: ${drv.pname or drv.name} ${version} vendors rust deps; its history entry needs a cargoHash (nix run .#scripts.history -- add <attr>==${version} re-derives it)"
        (lib.throwIf (!(old.cargoDeps ? vendorStaging))
          "load-packages: ${drv.pname or drv.name} ${version}: cargoDeps has no vendorStaging, so nixpkgs' vendor mechanism moved; the history rebase needs updating"
          (old.cargoDeps.overrideAttrs (o: {
            vendorStaging = o.vendorStaging.overrideAttrs (_: {
              inherit src;
              outputHash = spec.cargoHash;
            });
          })));
    pinned = drv.overrideAttrs (old:
      {
        inherit version src;
        # The entry itself, for a package whose drift the generic rebase can't
        # cover: a lock that moved (cargoRoot) has to be corrected in the
        # package file, which then rebuilds the vendor from this spec.
        # passthru only, so it moves no drvPath.
        passthru =
          (old.passthru or {})
          // {wasix = (old.passthru.wasix or {}) // {historySpec = spec;};};
      }
      // lib.optionalAttrs (old ? cargoDeps) {cargoDeps = rustVendor old;});
  in
    pinned // {override = args: pinToHistory version spec (drv.override args);};

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
      # A release whose own lock does not resolve its manifest vendors from one
      # kept beside the package file, which is the only thing that knows where
      # its sources live; the entry names it relative to there.
      lockFile = spec0.vendorLayout.lockFile or null;
      spec =
        if lockFile == null
        then spec0
        else
          lib.throwIf (s.file == null)
          "load-packages: '${name}' names a vendorLayout lockFile but has no package file to resolve it against"
          (lib.throwIf (spec0.vendorLayout ? postPatch)
            "load-packages: '${name}' sets both vendorLayout.lockFile and vendorLayout.postPatch; lockFile is written as the postPatch that copies it"
            (spec0
              // {
                vendorLayout =
                  builtins.removeAttrs spec0.vendorLayout ["lockFile"]
                  // {postPatch = "cp ${builtins.dirOf s.file + "/${lockFile}"} Cargo.lock";};
              }));
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
