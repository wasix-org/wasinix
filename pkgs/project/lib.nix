{lib}: let
  registryAttr = "__wasinixRegisteredPackages";
  extensionContextsAttr = "__wasinixExtensionContexts";
  unitOverlaysAttr = "__wasinixUnitOverlays";
  historyBaseAttr = "__wasinixHistoryBase";
  historyOverlaysAttr = "__wasinixHistoryOverlays";
  machineMetadata = ["source" "lineage" "instance" "definition" historyBaseAttr historyOverlaysAttr];

  scriptAttrs = [
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

  mergeScript = fragments:
    lib.concatStringsSep "\n" (lib.filter (fragment: fragment != null && fragment != "") fragments);

  extendAttrs = old:
    lib.mapAttrs (
      name: value: let
        previous = old.${name} or null;
      in
        if builtins.isFunction value
        then value previous
        else if builtins.elem name scriptAttrs
        then mergeScript [previous value]
        else if builtins.isList value
        then
          (
            if previous == null
            then []
            else previous
          )
          ++ value
        else if lib.isAttrs value && !lib.isDerivation value && lib.isAttrs previous && !lib.isDerivation previous
        then previous // extendAttrs previous value
        else value
    );

  extendPackage = package: attrs:
    package.overrideAttrs (old: extendAttrs old attrs);

  callWith = available: function: let
    formals = builtins.functionArgs function;
    missing = lib.filter (name: !formals.${name} && !(builtins.hasAttr name available)) (lib.attrNames formals);
  in
    lib.throwIf (missing != [])
    "missing required package-unit argument(s): ${lib.concatStringsSep ", " missing}"
    (function (builtins.intersectAttrs formals available));

  unitResult = {
    context,
    file,
    name,
    previous ? null,
  }: let
    function = import file;
    previousRegistered = previous != null && ((packageMetadata previous).source or null) != null;
    exposePackage = package: {
      ${name} =
        if previousRegistered
        then package
        else
          package.overrideAttrs (old: {
            passthru =
              (old.passthru or {})
              // {
                wasinix = builtins.removeAttrs ((old.passthru or {}).wasinix or {}) machineMetadata;
              };
          });
    };
    exposeExtendedPackage = attrs:
      if previous == null
      then throw "${name}: exposeExtendedPackage requires a preceding package"
      else exposePackage (extendPackage previous attrs);
    value =
      callWith (
        context
        // {
          inherit exposeExtendedPackage exposePackage;
        }
        // lib.optionalAttrs (previous != null) {package = previous;}
      )
      function;
    packages =
      lib.mapAttrs (
        resultName: package:
          lib.throwIf (!lib.isDerivation package)
          "package unit ${toString file} returned non-derivation attribute '${resultName}'"
          package
      )
      value;
  in
    lib.throwIf (!builtins.isFunction function)
    "package unit ${toString file} must be a function"
    (lib.throwIf (lib.isDerivation value)
      "package unit ${toString file} returned a bare derivation; use exposePackage"
      (lib.throwIf (!lib.isAttrs value)
        "package unit ${toString file} must return an attribute set of derivations"
        packages));

  discoverUnits = dir: let
    entries = builtins.readDir dir;
    files =
      map (name: {
        inherit name;
        directory = null;
        file = dir + "/${name}.nix";
      })
      (lib.filter (name: name != "default" && name != "history")
        (map (lib.removeSuffix ".nix")
          (lib.attrNames (lib.filterAttrs (name: type: type == "regular" && lib.hasSuffix ".nix" name) entries))));
    directories =
      map (name: {
        inherit name;
        directory = dir + "/${name}";
        file = dir + "/${name}/package.nix";
      })
      (lib.filter (name: builtins.pathExists (dir + "/${name}/package.nix"))
        (lib.attrNames (lib.filterAttrs (_: type: type == "directory") entries)));
  in
    files ++ directories;

  mergeDisjoint = state: unit: let
    duplicate = lib.intersectLists (lib.attrNames state) (lib.attrNames unit);
  in
    lib.throwIf (duplicate != [])
    "package units define duplicate attribute(s): ${lib.concatStringsSep ", " duplicate}"
    (state // unit);

  packageMetadata = package: (package.passthru or {}).wasinix or {};

  addressSegment = segment:
    if builtins.match "[A-Za-z_][A-Za-z0-9_'-]*" segment != null
    then ".${segment}"
    else "[${builtins.toJSON segment}]";

  address = root: segments:
    root + lib.concatMapStrings addressSegment segments;

  loadPackageOverlays = directories:
    lib.mapAttrs (_: directory: {
      __wasinixPackageDirectory = true;
      inherit directory;
    })
    directories;

  stampPackage = {
    definition ? null,
    name,
    package,
    previous ? null,
    previousSet,
    overlay,
    source,
    instance ? {
      kind = "current";
      version = toString (package.version or package.name);
    },
  }: let
    metadata = packageMetadata package;
    previousMetadata =
      if previous == null || !lib.isDerivation previous
      then {}
      else packageMetadata previous;
    previousSource = previousMetadata.source or null;
    previousLineage = previousMetadata.lineage or (lib.optional (previousSource != null) previousSource);
    previousInstance = previousMetadata.instance or null;
    previousDefinition = previousMetadata.definition or null;
    previousHistoryBase = previousMetadata.${historyBaseAttr} or null;
    previousHistoryOverlays = previousMetadata.${historyOverlaysAttr} or [];
    declaredOverride = metadata.overrides or null;
    reservedChanged =
      if previousSource == null
      then
        metadata ? source
        || metadata ? lineage
        || metadata ? instance
        || metadata ? definition
        || builtins.hasAttr historyBaseAttr metadata
        || builtins.hasAttr historyOverlaysAttr metadata
      else
        (metadata.source or previousSource)
        != previousSource
        || (metadata.lineage or previousLineage) != previousLineage
        || (metadata.instance or previousInstance) != previousInstance
        || (metadata.definition or previousDefinition) != previousDefinition;
    lineage =
      if previousSource == null
      then [source]
      else if previousSource == source
      then previousLineage
      else previousLineage ++ [source];
    historyBase =
      if previousSource == source
      then previousHistoryBase
      else previousSet;
    historyLayer = {inherit definition overlay;};
    historyOverlays =
      if previousSource == source
      then previousHistoryOverlays ++ [historyLayer]
      else [historyLayer];
    overrideError =
      if previousSource == null && declaredOverride != null
      then "declares an override of '${declaredOverride}', but has no preceding registered owner"
      else if previousSource == source && declaredOverride != null
      then "declares an override inside source '${source}'"
      else if previousSource != null && previousSource != source && declaredOverride == null
      then "overrides source '${previousSource}' without declaring passthru.wasinix.overrides"
      else if previousSource != null && previousSource != source && declaredOverride != previousSource
      then "declares an override of '${declaredOverride}', but the preceding owner is '${previousSource}'"
      else null;
  in
    lib.throwIf reservedChanged
    "${source}.${name} sets reserved Wasinix provenance fields"
    (lib.throwIf (overrideError != null)
      "${source}.${name} ${overrideError}"
      (package.overrideAttrs (old: {
          passthru =
            (old.passthru or {})
            // {
              wasinix =
                builtins.removeAttrs metadata machineMetadata
                // {
                  inherit source lineage instance;
                  inherit definition;
                  ${historyBaseAttr} = historyBase;
                  ${historyOverlaysAttr} = historyOverlays;
                };
            };
        })
        // {versions = {};}));
in rec {
  inherit address addressSegment callWith discoverUnits extendAttrs extensionContextsAttr historyBaseAttr historyOverlaysAttr loadPackageOverlays machineMetadata mergeScript packageMetadata registryAttr stampPackage unitOverlaysAttr unitResult;

  inherit extendPackage;

  loadPackageOverlay = {
    contextFor,
    dir,
  }: final: prev: let
    instantiate = unit: final': prev':
      unitResult {
        inherit (unit) file name;
        context = contextFor {
          final = final';
          prev = prev';
        };
        previous = prev'.${unit.name} or null;
      };
    units = discoverUnits dir;
    results =
      map (unit: {
        definition = {
          inherit (unit) directory file;
        };
        result = instantiate unit final prev;
        replay = instantiate unit;
      })
      units;
    packages = builtins.foldl' mergeDisjoint {} (map (item: item.result) results);
    unitOverlays = builtins.foldl' (state: item:
      state
      // lib.genAttrs (lib.attrNames item.result) (_: {
        inherit (item) definition;
        overlay = item.replay;
      })) {}
    results;
  in
    packages // {${unitOverlaysAttr} = unitOverlays;};

  registerOverlay = {
    definition ? null,
    overlay,
    source,
    instanceFor ? _name: package: {
      kind = "current";
      version = toString (package.version or package.name);
    },
  }:
    lib.throwIf (builtins.match "[a-z0-9][a-z0-9._-]*" source == null)
    "invalid Wasinix extension ID '${source}'"
    (final: prev: let
      result = overlay final prev;
      unitOverlays = result.${unitOverlaysAttr} or {};
      visibleResult = builtins.removeAttrs result [unitOverlaysAttr];
      reserved = lib.intersectLists (lib.attrNames result) [registryAttr extensionContextsAttr];
      names = builtins.removeAttrs (lib.genAttrs (lib.attrNames visibleResult) (_: true)) [registryAttr extensionContextsAttr];
      stamped =
        lib.mapAttrs (
          name: value:
            if lib.isDerivation value
            then let
              unit = unitOverlays.${name} or null;
            in
              stampPackage {
                inherit name source;
                definition =
                  if unit == null
                  then definition
                  else unit.definition;
                package = value;
                previous = prev.${name} or null;
                previousSet = prev;
                overlay =
                  if unit == null
                  then overlay
                  else unit.overlay;
                instance = instanceFor name value;
              }
            else value
        )
        visibleResult;
    in
      lib.throwIf (reserved != [])
      "registered overlay '${source}' sets reserved attribute(s): ${lib.concatStringsSep ", " reserved}"
      (stamped
        // {
          ${registryAttr} = (prev.${registryAttr} or {}) // names;
        }));

  registeredNames = packageSet:
    lib.attrNames (packageSet.${registryAttr} or {});

  registeredPackages = packageSet: let
    names = registeredNames packageSet;
    registered = lib.genAttrs names (name: packageSet.${name});
  in
    lib.filterAttrs (
      _: package:
        lib.isDerivation package
        && (packageMetadata package).source or null != null
        && (packageMetadata package).catalog or true
    )
    registered;
}
