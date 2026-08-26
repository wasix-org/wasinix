{
  lib,
  projectLib ? import ./lib.nix {inherit lib;},
  rebasePackageOverride ? null,
}: let
  historyMeta = ["note" "variants" "cargoHash" "vendorLayout"];

  resolveHistoryLockFile = {
    definition,
    label,
    spec,
  }: let
    lockFile = spec.vendorLayout.lockFile or null;
  in
    if lockFile == null
    then spec
    else
      lib.throwIf (definition == null || (definition.file or null) == null)
      "${label}: history vendorLayout.lockFile requires a package definition"
      (lib.throwIf (spec.vendorLayout ? postPatch)
        "${label}: history vendorLayout sets both lockFile and postPatch"
        (spec
          // {
            vendorLayout =
              removeAttrs spec.vendorLayout ["lockFile"]
              // {postPatch = "cp ${dirOf definition.file + "/${lockFile}"} Cargo.lock";};
          }));

  defaultRebasePackage = version: spec: package: let
    fetchArgs = removeAttrs spec historyMeta;
    # fetchurl has no override interface, so release tarballs replace the
    # fixed-output fields directly.
    src =
      if package.src ? override
      then package.src.override fetchArgs
      else
        package.src.overrideAttrs (_: {
          urls = [spec.url];
          outputHash = spec.hash;
          name = baseNameOf spec.url;
        });
    # importCargoLock can rebuild from the new lock. fetchCargoVendor instead
    # needs the retained fixed-output hash for its staging derivation.
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
        "load-packages: ${package.pname or package.name} ${version} vendors rust deps; its history entry needs a cargoHash (nix run .#history -- add <attr>==${version} re-derives it)"
        (lib.throwIf (!(old.cargoDeps ? vendorStaging))
          "load-packages: ${package.pname or package.name} ${version}: cargoDeps has no vendorStaging, so nixpkgs' vendor mechanism moved; the history rebase needs updating"
          (old.cargoDeps.overrideAttrs (previous: {
            vendorStaging = previous.vendorStaging.overrideAttrs (_: {
              inherit src;
              outputHash = spec.cargoHash;
            });
          })));
    pinned = package.overrideAttrs (old:
      {
        inherit version src;
        passthru =
          (old.passthru or {})
          // {wasix = (old.passthru.wasix or {}) // {historySpec = spec;};};
      }
      // lib.optionalAttrs (old ? cargoDeps) {cargoDeps = rustVendor old;});
  in
    # Package units commonly call override before adding their adaptation.
    # Re-pin after each such call so it cannot restore the current source.
    pinned // {override = args: defaultRebasePackage version spec (package.override args);};
  rebasePackage =
    if rebasePackageOverride == null
    then defaultRebasePackage
    else rebasePackageOverride;

  historyTablesFor = extensions:
    lib.listToAttrs (map (extension:
      lib.nameValuePair extension.id
      (lib.mapAttrs (_: path: builtins.fromJSON (builtins.readFile path)) (extension.history or {})))
    extensions);

  historyDeclarationsFor = historyTables: extensions: scope:
    lib.concatMap (extension:
      map (name: {
        inherit name;
        source = extension.id;
      })
      (lib.attrNames ((historyTables.${extension.id} or {}).${scope} or {})))
    extensions;

  validateHistory = historyTables: extensions: scope: packageSets: let
    declarations = historyDeclarationsFor historyTables extensions scope;
    grouped = lib.groupBy (declaration: declaration.name) declarations;
    duplicates = lib.attrNames (lib.filterAttrs (_: values: lib.length values > 1) grouped);
    ownersFor = declaration:
      lib.unique (lib.filter (owner: owner != null) (map (
          packageSet:
            (packageSet.${projectLib.registryAttr} or {}).${declaration.name} or null
        )
        packageSets));
    invalid = lib.filter (declaration: ownersFor declaration != [declaration.source]) declarations;
  in
    lib.throwIf (duplicates != [])
    "multiple Wasinix sources retain history for ${scope} package(s): ${lib.concatStringsSep ", " duplicates}"
    (lib.throwIf (invalid != [])
      "${scope} history does not match its current package owner: ${lib.concatStringsSep ", " (map (declaration: let
        owners = ownersFor declaration;
      in "${declaration.source}.${declaration.name} (owners: ${lib.concatStringsSep ", " owners})")
      invalid)}"
      true);

  validateProject = {
    extensions,
    packageSets,
    ...
  }: let
    historyTables = historyTablesFor extensions;
  in
    validateHistory historyTables extensions "wasix" (lib.attrValues packageSets.wasix)
    && validateHistory historyTables extensions "python" (lib.attrValues packageSets.python);

  projectionContextFor = {
    entry,
    extensions,
    finalSet,
    packageTransformFor,
    repairPythonPackage,
    ...
  }: let
    historyTables = historyTablesFor extensions;
    specs = ((historyTables.${entry.source} or {}).${entry.scope} or {}).${entry.name} or {};
    replay = version: rawSpec: let
      spec = resolveHistoryLockFile {
        definition = entry.definition or null;
        label = "${entry.source}.${entry.name} ${version}";
        spec = rawSpec;
      };
      metadata = projectLib.packageMetadata entry.package;
      baseSet = metadata.${projectLib.historyBaseAttr};
      overlays = metadata.${projectLib.historyOverlaysAttr};
      rebased =
        lib.throwIf (!(baseSet ? ${entry.name}))
        "${entry.source}.${entry.name}: history requires a preceding package to rebase"
        (rebasePackage version spec baseSet.${entry.name});
      normalize = packageSet: candidate:
        packageTransformFor {
          inherit (entry) scope variant;
          inherit packageSet;
        }
        entry.name
        candidate;
      initial = baseSet // {${entry.name} = normalize baseSet rebased;};
      replayed = lib.foldl' (previous: layer: let
        next =
          previous
          // (projectLib.registerOverlay {
              inherit (layer) definition overlay;
              inherit (entry) source;
              instanceFor = resultName: result:
                if resultName == entry.name
                then {
                  kind = "history";
                  inherit version;
                }
                else
                  (projectLib.packageMetadata
                    result).instance or {
                    kind = "current";
                    version = toString (result.version or result.name);
                  };
            }
            finalSet
            previous);
        candidate = next.${entry.name};
        pinned =
          if toString candidate.version == version
          then candidate
          else rebasePackage version spec candidate;
      in
        next
        // {${entry.name} = normalize previous pinned;})
      initial
      overlays;
      replayResult =
        if entry.scope == "python"
        then repairPythonPackage replayed.${entry.name}
        else replayed.${entry.name};
      result = replayResult.overrideAttrs (old: let
        oldPassthru = old.passthru or {};
        oldWasinix = oldPassthru.wasinix or {};
        oldCi = oldWasinix.ci or {};
      in {
        passthru =
          oldPassthru
          // {
            wasinix =
              oldWasinix
              // {
                ci = oldCi // {tags = lib.unique ((oldCi.tags or []) ++ ["history-tests"]);};
              };
          };
      });
    in
      lib.throwIf (toString result.version != version)
      "${entry.source}.${entry.name}: history requested ${version}, but replay produced ${toString result.version}"
      result;
  in {
    instantiateVersions = _candidate:
      lib.optionalAttrs (
        entry.kind
        == "package"
        && entry.instance.kind == "current"
      )
      (lib.mapAttrs replay specs);
  };
in {
  inherit historyMeta projectionContextFor rebasePackage resolveHistoryLockFile validateProject;
}
