# The WASIX overlay cargo registry's payload: one <version>+wasix.N.crate per
# version in crates.json (upstream .crate, the crate's edits applied, version
# restamped, repacked). scripts/crate-pins fills crates.json from each crate's
# `versions` constraint; output is inert data. See
# ../lib/wasix-crate-patches/README.md.
#
#   nix build .#cargoRegistry
{
  pkgs,
  lib,
  crateEdits,
  mkTestGroup,
}: let
  relPrefix = "cargoRegistry.crates.";
  rels = builtins.fromJSON (builtins.readFile ../../rels.json);
  relOf = crate: version: (rels."${relPrefix}${crate}" or {}).${version} or 1;

  pins = builtins.fromJSON (builtins.readFile ./crates.json);

  # Crates we publish: those with edits not marked notMinted. crate-pins pins only
  # these, so crates.json is exactly the mintable set.
  mintable = lib.filter (c: !(crateEdits.notMinted ? ${c})) crateEdits.crates;

  # One (crate, version) per crates.json entry.
  builds =
    lib.concatMap
    (crate: map (version: {inherit crate version;}) (lib.attrNames (pins.${crate} or {})))
    (lib.filter (c: pins ? ${c}) mintable);

  mint = {
    crate,
    version,
  }: let
    resolved = crateEdits.resolve crate version;
    rel = relOf crate version;
    wasixVersion = "${version}+wasix.${toString rel}";
    hash = pins.${crate}.${version};
    crateFile = "${crate}-${wasixVersion}.crate";
  in
    pkgs.stdenvNoCC.mkDerivation {
      pname = "wasix-crate-${crate}";
      version = wasixVersion;

      src = pkgs.fetchCrate {
        pname = crate;
        inherit version hash;
      };

      # The crate's patch stack (residuals + the floor patch), applied -p1 at the
      # crate root exactly as the vendor applies it.
      patches = resolved.patches;

      nativeBuildInputs = [(pkgs.python3.withPackages (ps: [ps.tomlkit]))];

      # patchPhase runs the crate's version-independent edits (rewriters); then
      # restamp the version. cargo package won't repackage a published crate (it
      # rejects the bundled Cargo.toml.orig) and would want the index to relock, so
      # a .crate is just a tar of the published files we restamp and repack.
      postPatch = ''
        ${resolved.patchPhase}
        python3 ${./bump-crate-version.py} . ${lib.escapeShellArg crate} \
          ${lib.escapeShellArg version} ${lib.escapeShellArg wasixVersion}
      '';

      buildPhase = ''
        runHook preBuild
        root="$NIX_BUILD_TOP/pack/${crate}-${wasixVersion}"
        mkdir -p "$root"
        cp -aT . "$root"
        runHook postBuild
      '';

      # The registry keys downloads by the tarball sha256, so the bytes must be
      # reproducible: fixed order/mtime/owner, gzip without its timestamp, files
      # only (as crates.io lays them out).
      installPhase = ''
        runHook preInstall
        mkdir -p "$out"
        cd "$NIX_BUILD_TOP/pack"
        find "${crate}-${wasixVersion}" \( -type f -o -type l \) -print0 \
          | LC_ALL=C sort -z \
          | tar --null --no-recursion --files-from=- \
              --mtime=@1 --owner=0 --group=0 --numeric-owner \
              --mode=go=rX,u+rw,a-s -cf - \
          | gzip -9n > "$out/${crateFile}"
        runHook postInstall
      '';

      passthru = {
        inherit crate version wasixVersion crateFile rel;
        wasix.supportedProfiles = [];
      };

      meta = {
        description = "WASIX build of the ${crate} crate (${wasixVersion})";
        platforms = lib.platforms.all;
      };
    };

  minted = map mint builds;

  manifest = {
    crates =
      map (d: {
        inherit (d.passthru) crate wasixVersion crateFile;
        upstream = d.passthru.version;
        inherit (d.passthru) rel;
      })
      minted;
    # A version outside a crate's `versions` is served stock from crates.io, so
    # the mint publishes no shadow limits: unminted versions simply pass through.
    shadowLimits = [];
    # Crates edited but not published (git-sourced, or a vendor-only rewrite), and
    # why, so their absence from the registry is recorded rather than silent.
    excluded = lib.mapAttrsToList (crate: reason: {inherit crate reason;}) crateEdits.notMinted;
  };

  registry = pkgs.linkFarm "wasix-cargo-registry" (
    map (d: {
      name = "crates/${d.passthru.crateFile}";
      path = "${d}/${d.passthru.crateFile}";
    })
    minted
    ++ [
      {
        name = "manifest.json";
        path = pkgs.writeText "manifest.json" (builtins.toJSON manifest);
      }
      {
        name = "publish-crate.py";
        path = ./publish-crate.py;
      }
    ]
  );

  # crate -> served upstream versions, read by scripts/update.py and bump-rel.py
  # via .#relVersions.
  crateVersions =
    lib.mapAttrs (_: ds: lib.unique (map (d: d.passthru.version) ds))
    (lib.groupBy (d: d.passthru.crate) minted);

  # rels.json keys under this prefix that no minted crate carries, left by an
  # upstream bump. scripts/update.py drops them; this surfaces hand bumps.
  staleRels = lib.concatMap (
    key: let
      name = lib.removePrefix relPrefix key;
    in
      lib.optionals (lib.hasPrefix relPrefix key)
      (map (v: "${key} ${v}")
        (lib.filter (v: !(lib.elem v (crateVersions.${name} or [])))
          (lib.attrNames rels.${key})))
  ) (lib.attrNames rels);

  tests = import ./tests.nix {
    inherit pkgs lib registry manifest;
  };
in
  registry.overrideAttrs (o: {
    passthru =
      (o.passthru or {})
      // {
        inherit manifest crateVersions;
        # crate -> `versions` constraint for the crates crate-pins should pin
        # (mintable only). Lazy, so forcing it doesn't force `minted`.
        pinConstraints =
          lib.filterAttrs (c: _: !(crateEdits.notMinted ? ${c})) crateEdits.edited;
        # cargoRegistry.crates.<name>."<upstream version>" rebuilds one build.
        crates =
          lib.mapAttrs (_: ds: lib.listToAttrs (map (d: lib.nameValuePair d.passthru.version d) ds))
          (lib.groupBy (d: d.passthru.crate) minted);
        tests = mkTestGroup "cargo-registry" tests;
        wasix.updateNotes = lib.optional (staleRels != []) {
          message = "rels.json has stale keys (${lib.concatStringsSep ", " staleRels}); nix run .#scripts.update -- --only nixpkgs drops them";
          when = _: _: true;
        };
      };
  })
