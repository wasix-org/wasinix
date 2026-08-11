# Apply the repository's WASIX crate edits to either nixpkgs vendor layout.
{
  lib,
  hostPkgs,
  crateEdits,
}: let
  startsWithDigit = s: builtins.match "[0-9].*" s != null;
  # Each entry carries the source it came from, since a crate vendored from git is
  # already whatever that fork ships and must not take a crates.io-authored floor.
  vendorCrateDirs = raw: let
    root = builtins.readDir raw;
    subdirs = lib.attrNames (lib.filterAttrs (_: t: t == "directory") root);
  in
    map (name: {
      inherit name;
      rel = name;
      git = false;
    }) (lib.attrNames root)
    ++ lib.concatMap (
      d:
        map (name: {
          inherit name;
          rel = "${d}/${name}";
          git = lib.hasPrefix "source-git" d;
        }) (lib.attrNames (builtins.readDir (raw + "/${d}")))
    )
    subdirs;

  presentEdits = predicate: raw:
    lib.filter (e: e != null) (
      map (
        entry: let
          crate =
            lib.findFirst (
              c: let
                v = lib.removePrefix "${c}-" entry.name;
              in
                lib.hasPrefix "${c}-" entry.name && startsWithDigit v
            )
            null
            crateEdits.crates;
        in
          # A git-sourced crate is skipped unless the crate is `notMinted`, which
          # marks edits authored against a git tree; everything else is floored
          # against a crates.io release, and a fork of the same version already
          # carries the port, so patching it again reverses it.
          if crate == null || (entry.git && !(crateEdits.notMinted ? ${crate}))
          then null
          else let
            version = lib.removePrefix "${crate}-" entry.name;
            state = crateEdits.stateOf crate version;
            candidate = {
              inherit crate version;
              inherit (entry) rel;
              resolved = crateEdits.resolve crate version;
            };
          in
            if !predicate candidate || state == "stock"
            then null
            else if state == "unsupported"
            then throw "wasix: ${crate} ${version} is unsupported (matches neither `edited` nor `stock` in wasix-crate-patches/${crate}/edits.nix); add it to `edited` (with a patch if needed) or to `stock`"
            else candidate
      )
      (vendorCrateDirs raw)
    );

  addsJson = hostPkgs.writeText "wasix-crate-adds.json" (builtins.toJSON crateEdits.adds);
  amendLockPy = ./amend-lock.py;
  addsCratesDir = hostPkgs.runCommand "wasix-adds-crates" {} (
    lib.concatMapStrings (a: ''
      mkdir -p "$out"
      tar xzf ${hostPkgs.fetchurl {
        url = "https://static.crates.io/crates/${a.name}/${a.name}-${a.version}.crate";
        sha256 = a.checksum;
      }} -C "$out"
      printf '{"files":{},"package":"${a.checksum}"}' \
        > "$out/${a.name}-${a.version}/.cargo-checksum.json"
    '')
    crateEdits.adds
  );

  applyOne = {
    crate,
    version,
    rel,
    resolved,
  }: ''
    d="$out"/${lib.escapeShellArg rel}
    [ -e "$d" ] || { echo "wasix: ${crate}-${version} not in vendor" >&2; exit 1; }
    if [ -L "$d" ]; then t="$d.wasix-real"; cp -rL "$d" "$t"; rm "$d"; mv "$t" "$d"; chmod -R u+w "$d"; fi
    (
      cd "$d"
      ${lib.concatMapStrings (p: "patch -p1 --no-backup-if-mismatch < ${p}\n      ") resolved.patches}
      ${resolved.patchPhase}
      jq '.files = {}' .cargo-checksum.json > .cargo-checksum.json.w
      mv .cargo-checksum.json.w .cargo-checksum.json
    )
  '';

  injectAdds = presents: let
    # An add belongs to the versions that actually pull it, so a consumer on a
    # version that does not declare it must not get the crate written into its
    # lock (watchfiles pins mio 1.0.3 and has no wasix in its vendor).
    need =
      lib.filter (a: lib.any (e: e.crate == a.crate && lib.elem e.version a.versions) presents)
      crateEdits.adds;
  in
    lib.optionalString (need != []) (
      lib.concatMapStrings (a: ''
        if ! find "$out" -maxdepth 2 \( -type d -o -type l \) -name ${lib.escapeShellArg "${a.name}-*"} | grep -q .; then
          adder=$(find "$out" -maxdepth 2 -type d -name ${lib.escapeShellArg "${a.crate}-*"} -print -quit)
          [ -n "$adder" ] && cp -a ${addsCratesDir}/${a.name}-${a.version} "$(dirname "$adder")/"
        fi
      '')
      need
      + ''
        _l=$(find "$out" -maxdepth 2 -name Cargo.lock -print -quit)
        [ -n "$_l" ] && { ${hostPkgs.python3}/bin/python3 ${amendLockPy} "$_l" ${addsJson} > "$_l.w"; mv "$_l.w" "$_l"; }
      ''
    );

  applyPlan = presents:
    lib.optionalString (presents != []) (
      ''
        chmod -R u+w "$out"
      ''
      + lib.concatMapStrings applyOne presents
      + injectAdds presents
    );

  # `presents` reads the vendor tree, so it stays inside overrideAttrs: resolving
  # it while the package set evaluates would force that IFD on every consumer.
  patchInPlaceWhere = predicate: raw:
    raw.overrideAttrs (o: let
      presents = presentEdits predicate raw;
    in {
      nativeBuildInputs =
        (o.nativeBuildInputs or [])
        ++ lib.optionals (presents != []) [hostPkgs.jq hostPkgs.python3];
      buildCommand = (o.buildCommand or "") + applyPlan presents;
    });

  patchFarm = raw: let
    presents = presentEdits (_: true) raw;
  in
    if presents == []
    then raw
    else
      hostPkgs.runCommand (raw.name or "cargo-deps") {
        nativeBuildInputs = [hostPkgs.jq hostPkgs.python3];
      } ''
        mkdir "$out"
        shopt -s dotglob
        for e in ${raw}/*; do ln -s "$e" "$out/$(basename "$e")"; done
        ${applyPlan presents}
      '';
in {
  inherit patchInPlaceWhere patchFarm;
  patchInPlace = patchInPlaceWhere (_: true);

  mkLockAmendHook = targetPkgs:
    targetPkgs.makeSetupHook {name = "wasix-lock-amend-hook";}
    (targetPkgs.buildPackages.writeText "wasix-lock-amend-hook.sh" ''
      _wasixAmendSourceLock() {
        local l="''${cargoRoot:+$cargoRoot/}Cargo.lock"
        [ -f "$l" ] || return 0
        ${hostPkgs.python3}/bin/python3 ${amendLockPy} "$l" ${addsJson} > "$l.wasix"
        mv "$l.wasix" "$l"
      }
      postPatchHooks=(_wasixAmendSourceLock ''${postPatchHooks[@]+"''${postPatchHooks[@]}"})
    '');
}
