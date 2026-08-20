{lib}: let
  registryAttr = "__wasinixRegisteredPackages";

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
    value = callWith (context // lib.optionalAttrs (previous != null) {package = previous;}) function;
    packages =
      if lib.isDerivation value
      then {${name} = value;}
      else value;
    invalid = lib.filterAttrs (_: package: !lib.isDerivation package) packages;
  in
    lib.throwIf (!builtins.isFunction function)
    "package unit ${toString file} must be a function"
    (lib.throwIf (!lib.isAttrs packages)
      "package unit ${toString file} must return a derivation or an attribute set of derivations"
      (lib.throwIf (invalid != {})
        "package unit ${toString file} returned non-derivation attribute(s): ${lib.concatStringsSep ", " (lib.attrNames invalid)}"
        packages));

  discoverUnits = dir: let
    entries = builtins.readDir dir;
    files =
      map (name: {
        inherit name;
        file = dir + "/${name}.nix";
      })
      (lib.filter (name: name != "default" && name != "history")
        (map (lib.removeSuffix ".nix")
          (lib.attrNames (lib.filterAttrs (name: type: type == "regular" && lib.hasSuffix ".nix" name) entries))));
    directories =
      map (name: {
        inherit name;
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

  stampPackage = {
    name,
    package,
    previous ? null,
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
    previousLineage = previousMetadata.lineage or lib.optional (previousSource != null) previousSource;
    previousInstance = previousMetadata.instance or null;
    declaredOverride = metadata.overrides or null;
    reservedChanged =
      if previousSource == null
      then metadata ? source || metadata ? lineage || metadata ? instance
      else
        (metadata.source or previousSource)
        != previousSource
        || (metadata.lineage or previousLineage) != previousLineage
        || (metadata.instance or previousInstance) != previousInstance;
    lineage =
      if previousSource == null
      then [source]
      else if previousSource == source
      then previousLineage
      else previousLineage ++ [source];
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
              builtins.removeAttrs metadata ["source" "lineage" "instance"]
              // {inherit source lineage instance;};
          };
      })));
in rec {
  inherit address addressSegment callWith discoverUnits extendAttrs mergeScript packageMetadata registryAttr stampPackage unitResult;

  extendPackage = package: attrs:
    package.overrideAttrs (old: extendAttrs old attrs);

  loadPackageOverlay = {
    contextFor,
    dir,
  }: final: prev: let
    context = contextFor {inherit final prev;};
    instantiate = unit:
      unitResult {
        inherit (unit) file name;
        inherit context;
        previous = prev.${unit.name} or null;
      };
  in
    builtins.foldl' mergeDisjoint {} (map instantiate (discoverUnits dir));

  registerOverlay = {
    overlay,
    source,
  }:
    lib.throwIf (builtins.match "[a-z0-9][a-z0-9._-]*" source == null)
    "invalid Wasinix extension ID '${source}'"
    (final: prev: let
      result = overlay final prev;
      names = builtins.removeAttrs (lib.genAttrs (lib.attrNames result) (_: true)) [registryAttr];
      stamped =
        lib.mapAttrs (
          name: value:
            if lib.isDerivation value
            then
              stampPackage {
                inherit name source;
                package = value;
                previous = prev.${name} or null;
              }
            else value
        )
        result;
    in
      lib.throwIf (result ? ${registryAttr})
      "registered overlay '${source}' sets reserved attribute '${registryAttr}'"
      (stamped
        // {
          ${registryAttr} = (prev.${registryAttr} or {}) // names;
        }));

  registeredPackages = packageSet: let
    names = lib.attrNames (packageSet.${registryAttr} or {});
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
