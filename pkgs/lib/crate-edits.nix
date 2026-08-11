# Eval-time view of wasix-crate-patches/: each crate's edits (edits.nix + its
# <version>.patch files), enumerated once so vendor patching and the registry
# mint resolve the same spec. `floorFor` is the single version selector; both
# consumers call `resolve` to get the {patches, patchPhase, adds} for a version.
# `pins` is cargo-registry/crates.json, the enumeration of the versions we cover.
# See wasix-crate-patches/README.md.
{
  pkgs,
  pins,
}: dir: let
  lib = pkgs.lib;
  rewriters = import (dir + "/rewriters") {inherit pkgs;};
  adds = import (dir + "/adds.nix");
  helpers = import (dir + "/helpers.nix") {inherit lib;};

  skip = ["rewriters" "__pycache__"];
  crateNames =
    lib.filter (n: !(lib.elem n skip))
    (lib.attrNames (lib.filterAttrs (_: t: t == "directory") (builtins.readDir dir)));

  # A comparator constraint: terms (>= <= < > =) comma-AND'd per element, the
  # array OR'd; `*` matches anything. The single coverage / version-match impl.
  matches = constraints: version: let
    cmp = op: let
      c = builtins.compareVersions version;
    in
      term: let
        r = c term;
      in
        if op == ">="
        then r >= 0
        else if op == "<="
        then r <= 0
        else if op == "<"
        then r < 0
        else if op == ">"
        then r > 0
        else r == 0;
    termOk = term:
      if term == "*"
      then true
      else let
        m = builtins.match " *(>=|<=|=|<|>) *([^ ]+) *" term;
      in
        if m == null
        then throw "crate-edits: bad constraint term '${term}'"
        else cmp (builtins.elemAt m 0) (builtins.elemAt m 1);
    constraintOk = c: lib.all termOk (lib.splitString "," c);
  in
    lib.any constraintOk constraints;

  editsOf = crate: let
    crateDir = dir + "/${crate}";
    files = builtins.readDir crateDir;
    spec =
      if files ? "edits.nix"
      then import (crateDir + "/edits.nix") {inherit lib rewriters adds helpers;}
      else throw "crate-edits: ${crate} has no edits.nix";
    isPatch = n: t:
      t == "regular" && lib.hasSuffix ".patch" n && builtins.match "[0-9].*" n != null;
    patchFiles =
      lib.mapAttrsToList (n: _: {
        version = lib.removeSuffix ".patch" n;
        path = crateDir + "/${n}";
      })
      (lib.filterAttrs isPatch files);
  in
    spec // {inherit crate patchFiles;};

  edits = lib.listToAttrs (map (c: lib.nameValuePair c (editsOf c)) crateNames);

  # The floor patch path for a covered version: highest <version>.patch <= it, or
  # null if the version is outside coverage or below the lowest patch.
  floorFor = crate: version: let
    e = edits.${crate};
    cands = lib.filter (p: builtins.compareVersions p.version version <= 0) e.patchFiles;
  in
    if !(matches e.edited version) || cands == []
    then null
    else (lib.last (lib.sort (a: b: builtins.compareVersions a.version b.version < 0) cands)).path;

  # The concrete spec for a (crate, version): floorFor picks the patch, forVersion
  # (which may branch on version) composes the stack, phase, and adds.
  resolve = crate: version: let
    e = edits.${crate};
    floorPatch = floorFor crate version;
    fv =
      if e ? forVersion
      then e.forVersion {inherit version floorPatch;}
      else {patches = lib.optional (floorPatch != null) floorPatch;};
  in {
    patches = fv.patches or (lib.optional (floorPatch != null) floorPatch);
    patchPhase = fv.patchPhase or "";
    adds = fv.adds or [];
  };
  # Deps crates pull in that upstream lacks (mio -> wasix), tagged with the adder
  # and the exact versions that pull it. `adds` is declared per version inside
  # forVersion, so the versions come from `pins` -- the enumeration of what we
  # cover. Patch files are never iterated for this: their names floor a version
  # that is already known, they are not a version list.
  addsFor = crate: let
    versions = lib.attrNames (pins.${crate} or {});
    tagged = lib.concatMap (v: map (a: {inherit v a;}) (resolve crate v).adds) versions;
    byAdd = lib.groupBy (t: "${t.a.name}-${t.a.version}") tagged;
  in
    lib.mapAttrsToList (
      _: ts:
        (lib.head ts).a
        // {
          inherit crate;
          versions = lib.sort (a: b: builtins.compareVersions a b < 0) (map (t: t.v) ts);
        }
    )
    byAdd;
  # Tri-state for a resolved version of an edited crate: `edited` (apply our
  # patch stack + phase), `stock` (deliberately left as upstream ships it), or
  # `unsupported` (neither — a version we have not vetted). The vendor hard-fails
  # on `unsupported` so a crate silently drifting past its edited range surfaces
  # loudly instead of miscompiling downstream.
  stateOf = crate: version: let
    e = edits.${crate};
  in
    if matches e.edited version
    then "edited"
    else if matches (e.stock or []) version
    then "stock"
    else "unsupported";
in {
  inherit floorFor resolve stateOf;
  crates = crateNames;
  edited = lib.mapAttrs (_: e: e.edited) edits;
  stock = lib.mapAttrs (_: e: e.stock or []) edits;
  notMinted = lib.filterAttrs (_: v: v != null) (lib.mapAttrs (_: e: e.notMinted or null) edits);
  adds = lib.concatMap addsFor crateNames;
}
