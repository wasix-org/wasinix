# The spot-override splice: re-evaluate the package sets with a pristine
# evaluation's builds pinned everywhere except under the targets, so only those
# targets (and what they need from the working tree) rebuild. See ../spot.nix for
# the entry point and the caveats; this file is only the wiring.
{
  lib,
  # spotOverlays -> the wasix package sets (flake.nix's import of ./pkgs).
  mkWasix,
  # The overlay's package names: the attrs this tree can move other than
  # through the stdenv, and so the ones worth pinning.
  pkgNames,
}: {
  # nixpkgsByProfile from the pristine base evaluation.
  baseByProfile,
  # One or more dotted attr paths into nixpkgsByProfile, e.g. ["exnrefEh.zlib"].
  # A nested path ("exnrefEhpic.python314.pkgs.numpy") unpins its top-level owner.
  # All targets share one splice: every target's owner is kept, so co-tested
  # targets see each other on the working tree, and everything else is pinned to
  # base once (one evaluation, not one per target).
  targets,
  # keep is a set of attrs to build from the working tree; everything else comes
  # from base. Terms are attr names or aliases (cc, rust, haskell, toolchain =
  # the three, all = every attr, none = empty); a "-" prefix removes from what
  # precedes it. ["toolchain" "zlib"] is the toolchains plus zlib; ["zlib"] is
  # only zlib; ["all" "-rust"] is every attr but the rust toolchain. A keep of
  # only removals has no base and is an error. Applied only when set; absent, it
  # defaults to ["toolchain"]. The targets themselves are always kept, on top.
  keep ? ["toolchain"],
}: let
  # ── keep grammar (shared across targets) ──────────────────────────────────
  # The three toolchains. Each enters outside pkgNames (stdenv via
  # replaceCrossStdenv, rustPlatform/haskellPackages as overlay attrs), so the
  # pin overlay has to name them explicitly to reach them. Ordinary members of
  # the keep namespace; they only stand out in that the default keep is exactly
  # them (`toolchain`).
  toolchainNames = ["stdenv" "rustPlatform" "haskellPackages"];
  allNames = pkgNames ++ toolchainNames;
  aliases = {
    cc = ["stdenv"];
    rust = ["rustPlatform"];
    haskell = ["haskellPackages"];
    toolchain = toolchainNames;
    all = allNames;
    none = [];
  };
  expand1 = n: aliases.${n} or [n];
  # A term adds, or removes when "-"-prefixed. keepNames is the additions minus
  # the removals; a removal only ever pares down a base you named (all,-rust), so
  # a keep of only removals is rejected below rather than conjured from `all`.
  addTerms = lib.filter (t: !(lib.hasPrefix "-" t)) keep;
  subs = lib.concatMap expand1 (map (lib.removePrefix "-") (lib.filter (lib.hasPrefix "-") keep));
  adds = lib.concatMap expand1 addTerms;
  keepNames = lib.subtractLists subs adds;
  unknown = lib.filter (n: !(lib.elem n allNames)) (adds ++ subs);

  # ── per-target parse ──────────────────────────────────────────────────────
  parse = target: let
    path = lib.splitString "." target;
    profile = lib.head path;
    attrPath = lib.tail path;
    leafPath = lib.tail attrPath;
    baseSet = baseByProfile.${profile};
    # The scope holding a nested leaf, base side (e.g. base python314.pkgs).
    baseScope =
      if leafPath != []
      then lib.getAttrFromPath (lib.init attrPath) baseSet
      else {};
    builderOverride = (baseScope.buildPythonPackage or {}).override or null;
  in {
    inherit target path profile attrPath leafPath baseSet builderOverride;
    owner = lib.head attrPath;
    nested = leafPath != [];
    # Nested python target (python314.pkgs.numpy): recompile the extension
    # without rebuilding the interpreter. Its compiler comes from
    # buildPythonPackage (nixpkgs python-packages-base.nix), not the package's
    # own stdenv arg and not the scope, so swapping just buildPythonPackage's
    # stdenv moves the wheel and leaves the interpreter and its scope pinned. Off
    # when the scope has no overridable buildPythonPackage (not a python
    # extension), or when keep names the owner: that unpins the interpreter so
    # you can test an edit to its own definition, which the base scope lacks.
    swapBuilder = builderOverride != null && !(lib.elem (lib.head attrPath) keepNames);
    # Kept safe on a malformed target (owner/baseSet stay unforced) so the error
    # is reported rather than a raw builtins.head/attr crash.
    error =
      if lib.length path < 2
      then "target must be a dotted <profile>.<attr>, got \"${target}\""
      else if !(baseByProfile ? ${profile})
      then "unknown profile \"${profile}\" in \"${target}\" (have: ${lib.concatStringsSep ", " (lib.attrNames baseByProfile)})"
      else if !(lib.hasAttrByPath attrPath baseSet)
      then "unknown target \"${target}\""
      else null;
  };
  parsed = map parse targets;

  # Validation, reported through the splice's own error rather than a silent
  # no-op: an unknown keep name (or a bad target) would just fail to move.
  errors =
    lib.optional (unknown != []) "unknown keep name(s): ${lib.concatStringsSep ", " unknown} (an overlay package, a toolchain, or cc/rust/haskell/toolchain/all/none; prefix - to remove)"
    ++ lib.optional (addTerms == [] && subs != []) "keep has only removals; name a base to remove from, e.g. all,-rust or toolchain,-rust"
    ++ lib.filter (e: e != null) (map (t: t.error) parsed);

  # ── the cut: keep-named attrs plus every target's owner (in its own profile)
  # come from the working tree; the same splice serves all targets ────────────
  ownersUnpinnedIn = p: map (t: t.owner) (lib.filter (t: t.profile == p && !t.swapBuilder) parsed);
  unpinnedIn = p: keepNames ++ ownersUnpinnedIn p;
  # Guarded on isWasix: an overlay applies to every stage, and these names are
  # cross builds, so replacing them in buildPackages swaps native build tools for
  # wasm ones and drags in a full native bootstrap. Pinning final.stdenv this way
  # is fine (it does not re-enter the stdenv bootstrap, which reads the
  # lower-stage attrs, not final.stdenv).
  pinOverlay = p: [
    (
      final: prev:
        lib.optionalAttrs (prev.stdenv.hostPlatform.isWasix or false)
        (
          lib.genAttrs (lib.filter (n: !(lib.elem n (unpinnedIn p))) allNames)
          (n: baseByProfile.${p}.${n} or prev.${n})
        )
    )
  ];
  spotWasix = mkWasix (lib.genAttrs (lib.attrNames baseByProfile) pinOverlay);

  # ── second pin layer: function args the overlay pin (above) misses ──────────
  # That pin only rewrites final.<name> for pkgNames; a target can still take a
  # wasix dep that is a plain nixpkgs package with no overlay entry (coreutils,
  # gawk, gnugrep: the shell tools a CLI like git shells out to), which layer 1
  # leaves on the work tree. Left alone, git would rebuild that whole shell-tool
  # closure under the work toolchain. Applied per target (its profile/baseSet):
  # pin an arg only when it is a wasix build (skips native tzdata/bash and
  # nixpkgs' throwing `python` stub) whose name resolves to a base derivation.
  isDrv = v: (builtins.tryEval (lib.isDerivation v)).value;
  isWasixDrv = v: (builtins.tryEval (v.stdenv.hostPlatform.isWasix or false)).value;
  pinArg = t: name: value: let
    baseValue = (builtins.tryEval (t.baseSet.${name} or null)).value;
  in
    if lib.elem name (unpinnedIn t.profile) || !(isWasixDrv value) || !(isDrv baseValue)
    then value
    else baseValue;
  pinArgsOf = t: pkg:
    if pkg ? override
    then pkg.override (args: lib.mapAttrs (pinArg t) args)
    else pkg;

  # ── per-target splice + report ──────────────────────────────────────────────
  resultOf = t: let
    spotSet = spotWasix.nixpkgsByProfile.${t.profile};
    basePkg = lib.getAttrFromPath t.attrPath t.baseSet;
    ownerPinned = pinArgsOf t spotSet.${t.owner};
    spliced =
      if t.swapBuilder
      then basePkg.override {buildPythonPackage = t.builderOverride {stdenv = spotSet.stdenv;};}
      else if t.nested
      then pinArgsOf t (lib.getAttrFromPath t.leafPath ownerPinned)
      else ownerPinned;
  in {
    inherit (t) target;
    inherit spliced;
    baseDrv = basePkg;
    # Guards a silent no-op: if the working-tree change cannot reach a target,
    # its splice equals base and that target tests nothing.
    changed = spliced.drvPath != basePkg.drvPath;
    mode =
      if t.swapBuilder
      then "builder-swap (interpreter pinned)"
      else if t.nested
      then "owner-unpinned (interpreter rebuilds)"
      else "direct";
  };
  results = map resultOf parsed;
in
  if errors != []
  then throw ("spot: " + lib.concatStringsSep "; " errors)
  else {
    # Lists, one entry per target; nix build realises them all.
    spliced = map (r: r.spliced) results;
    baseDrv = map (r: r.baseDrv) results;
    report = {
      keep = keepNames;
      # Which toolchains ended up on the working tree, read off the actual cut.
      keptToolchains = lib.filter (n: lib.elem n keepNames) toolchainNames;
      # For the driver's no-op guard: proceed if any target moved (a target that
      # did not just cache-hits, contributing nothing to the build).
      changed = lib.any (r: r.changed) results;
      targets =
        map (r: {
          inherit (r) target changed mode;
          baseDrvPath = r.baseDrv.drvPath;
          splicedDrvPath = r.spliced.drvPath;
        })
        results;
    };
  }
