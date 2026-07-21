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
  historyMeta = ["note" "variants"];
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
  # (function, file) for a name, for history re-imports. Only single-function
  # packages: a version family (icu) already IS multi-version in nixpkgs, and a
  # trivial name has no tweak file to re-run conditionals in.
  sourceOf = name:
    if builtins.elem name fileNames
    then {
      fn = import (dir + "/${name}.nix");
      file = dir + "/${name}.nix";
    }
    else if builtins.elem name dirNames && !(isMulti (dirEntry name))
    then {
      fn = dirEntry name;
      file = dir + "/${name}/package.nix";
    }
    else throw "load-packages: history for '${name}' needs a single-function package file";

  # `<set>` with `<set>.<name>` rebased onto a history version, reusing the
  # package's OWN fetcher: src.override with the spec's fetch args (rev/tag/
  # version + hash). fetchurl release tarballs aren't overridable, so patch the
  # src derivation's url + hash directly (spec carries `url`). Survives the
  # `.override` many package files call (it re-runs the nixpkgs function, which
  # would drop a plain overrideAttrs) by re-pinning the src after each override.
  rebaseHistory = set: name: version: spec: let
    base = set.${name};
    fetchArgs = builtins.removeAttrs spec historyMeta;
    src =
      if base.src ? override
      then base.src.override fetchArgs
      else
        base.src.overrideAttrs (_: {
          urls = [spec.url];
          outputHash = spec.hash;
          name = baseNameOf spec.url;
        });
    pin = drv: let
      pinned = drv.overrideAttrs (_: {
        inherit version src;
      });
    in
      pinned // {override = args: pin (drv.override args);};
  in
    set // {${name} = pin base;};

  # everything this dir declares outright, before history mints anything
  declaredNames =
    fileNames
    ++ lib.concatMap (
      n: let
        e = dirEntry n;
      in
        if isMulti e
        then e.names
        else [n]
    )
    dirNames
    ++ trivial;
in {
  names = declaredNames ++ historyNames;

  # Instantiate the set: every package file is a function over one `callArgs`
  # attrset; trivial names go through `mkTrivial`.
  mkPackages = {
    callArgs,
    mkTrivial ? name: throw "load-packages: '${name}' is in the trivial list but no mkTrivial was given",
    # meta.position for the trivial names (the list that declares them)
    trivialPosition ? null,
  }: let
    stampTrivial =
      if trivialPosition != null
      then stampPosition trivialPosition
      else lib.id;
    historyDrv = name: version: spec: let
      s = sourceOf name;
      built = s.fn (callArgs // {${historyFrom} = rebaseHistory callArgs.${historyFrom} name version spec;});
    in
      stampPosition s.file (built.overrideAttrs (o: {
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
    ((lib.genAttrs trivial (n: stampTrivial (mkTrivial n)))
      // (lib.genAttrs fileNames (n: stampPosition (dir + "/${n}.nix") (import (dir + "/${n}.nix") callArgs)))
      // (builtins.foldl' (
          acc: n: let
            e = dirEntry n;
            file = dir + "/${n}/package.nix";
          in
            acc
            // (
              if isMulti e
              then lib.mapAttrs (_: stampPosition file) (e.packages callArgs)
              else {${n} = stampPosition file (e callArgs);}
            )
        ) {}
        dirNames)
      // historyPackages);
}
