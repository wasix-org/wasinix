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

  orEmpty = values:
    if values == null
    then []
    else values;

  dropInputsByName = names: values:
    builtins.filter (value: value != null && !(builtins.elem (lib.getName value) names)) (orEmpty values);

  dropInputsByNameInfix = names: values:
    builtins.filter (value: value != null && !(lib.any (name: lib.hasInfix name (lib.getName value)) names)) (orEmpty values);

  replaceInputsByName = replacements: values:
    map (value:
      if value == null
      then value
      else replacements.${lib.getName value} or value)
    (orEmpty values);

  linkInputs = update: {
    buildInputs = update;
    propagatedBuildInputs = update;
  };

  dropPatchesByNameInfix = names:
    builtins.filter (patch: !(lib.any (name: lib.hasInfix name (baseNameOf (toString patch))) names));

  dropFlagsByPrefix = prefixes:
    builtins.filter (flag: !(lib.any (prefix: lib.hasPrefix prefix flag) prefixes));

  buildHostPypaTools = buildPython: old:
    dropInputsByName ["pip" "wheel" "setuptools"] old
    ++ [buildPython.pkgs.pip buildPython.pkgs.wheel buildPython.pkgs.setuptools];

  dropSphinxDocs = extraNames: {
    nativeBuildInputs = dropInputsByNameInfix (["sphinx"] ++ extraNames);
    outputs = outputs:
      lib.filter (output: output != "doc") (
        if outputs == null
        then ["out"]
        else outputs
      );
  };

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

  extendPythonPackage = repair: package: attrs: let
    buildAttrs = [
      "patches"
      "pname"
      "postBuild"
      "postPatch"
      "preBuild"
      "prePatch"
      "src"
      "version"
    ];
    changesBuild = lib.any (name: builtins.hasAttr name attrs) buildAttrs;
    extended = extendPackage package attrs;
    stamped =
      if changesBuild
      then
        extended.overrideAttrs (old: let
          passthru = old.passthru or {};
          wasinix = passthru.wasinix or {};
        in {
          passthru =
            passthru
            // {
              wasinix =
                wasinix
                // {
                  publication = (wasinix.publication or {}) // {supersedesPyPI = true;};
                };
            };
        })
      else extended;
  in
    repair stamped;

  wasmRename = {
    wasmName,
    posixAlias ? false,
  }: package:
    package.overrideAttrs (old: {
      postInstall = mergeScript [
        (old.postInstall or "")
        ''
          for _bindir in "$out" ''${bin:+"$bin"}; do
            if [ -f "$_bindir/bin/${wasmName}" ]; then
              mv "$_bindir/bin/${wasmName}" "$_bindir/bin/${wasmName}.wasm"
              for _link in "$_bindir/bin/"*; do
                if [ -L "$_link" ] && [ "$(basename "$(readlink "$_link")")" = "${wasmName}" ]; then
                  ln -sf "${wasmName}.wasm" "$_link"
                fi
              done
              ${lib.optionalString posixAlias ''ln -s "${wasmName}.wasm" "$_bindir/bin/${wasmName}"''}
            fi
          done
        ''
      ];
    });

  callWithLabel = label: available: function: let
    formals = builtins.functionArgs function;
    missing = lib.filter (name: !formals.${name} && !(builtins.hasAttr name available)) (lib.attrNames formals);
  in
    lib.throwIf (missing != [])
    "missing required ${label} argument(s): ${lib.concatStringsSep ", " missing}"
    (function (builtins.intersectAttrs formals available));

  callWith = callWithLabel "package-unit";

  loadTestDirectory = {
    context,
    dir,
  }: let
    entries = builtins.readDir dir;
    helperFile = dir + "/helpers.nix";
    helpers =
      if builtins.pathExists helperFile
      then let
        function = import helperFile;
        result =
          lib.throwIf (!builtins.isFunction function)
          "test helpers ${toString helperFile} must be a function"
          (callWithLabel "test-helper" context function);
      in
        lib.throwIf (!lib.isAttrs result || lib.isDerivation result)
        "test helpers ${toString helperFile} must return an attribute set"
        result
      else null;
    files =
      map (name: dir + "/${name}")
      (lib.filter (name: name != "helpers.nix" && name != "default.nix")
        (lib.attrNames (lib.filterAttrs (name: type: type == "regular" && lib.hasSuffix ".nix" name) entries)));
    load = file: let
      function = import file;
      result =
        lib.throwIf (!builtins.isFunction function)
        "test file ${toString file} must be a function"
        (callWithLabel "test" (context // lib.optionalAttrs (helpers != null) {inherit helpers;}) function);
      invalid = lib.filterAttrs (_: test: !lib.isDerivation test) result;
    in
      lib.throwIf (!lib.isAttrs result || lib.isDerivation result)
      "test file ${toString file} must return an attribute set"
      (lib.throwIf (invalid != {})
        "test file ${toString file} returned non-derivation test(s): ${lib.concatStringsSep ", " (lib.attrNames invalid)}"
        result);
    merge = state: file: let
      loaded = load file;
      duplicates = lib.intersectLists (lib.attrNames state) (lib.attrNames loaded);
    in
      lib.throwIf (duplicates != [])
      "test directory ${toString dir} defines duplicate test(s): ${lib.concatStringsSep ", " duplicates}"
      (state // loaded);
  in
    lib.foldl' merge {} files;

  withoutMachineMetadata = package:
    package.overrideAttrs (old: {
      passthru =
        (old.passthru or {})
        // {
          wasinix = removeAttrs ((old.passthru or {}).wasinix or {}) machineMetadata;
        };
    });

  unitResult = {
    context,
    extendPackageFor ? extendPackage,
    file,
    name,
    previous ? null,
    previousAvailable ? previous != null,
    previousRegistered ? previous != null && ((packageMetadata previous).source or null) != null,
    previousSet ? {},
  }: let
    function = import file;
    exposePackage = package: {
      ${name} =
        if previousRegistered
        then package
        else withoutMachineMetadata package;
    };
    exposeExtendedPackage = attrs:
      if !previousAvailable
      then throw "${name}: exposeExtendedPackage requires a preceding package"
      else exposePackage (extendPackageFor previous attrs);
    exposeNativePackage = package:
      exposePackage (package.overrideAttrs (old: {
        passthru =
          (old.passthru or {})
          // {
            wasix = ((old.passthru or {}).wasix or {}) // {supportedProfiles = [];};
          };
      }));
    exposePackageVariants = {
      native,
      wasix,
    }:
      exposePackage (
        if context.scope == "wasix"
        then wasix
        else native
      );
    exposeWasixPackage = candidate:
      if !previousAvailable
      then throw "${name}: exposeWasixPackage requires a preceding package"
      else if context.scope != "wasix"
      then throw "${name}: exposeWasixPackage is only valid in a WASIX package set"
      else exposePackage candidate;
    exposeWasixExtendedPackage = attrs:
      if !previousAvailable
      then throw "${name}: exposeWasixExtendedPackage requires a preceding package"
      else exposeWasixPackage (extendPackageFor previous attrs);
    exposeWasixExtendedPackages = updates:
      lib.mapAttrs (
        resultName: update:
          if !(builtins.hasAttr resultName previousSet)
          then throw "${name}: exposeWasixExtendedPackages requires preceding package '${resultName}'"
          else let
            base = previousSet.${resultName};
            candidate =
              if builtins.isFunction update
              then update base
              else extendPackageFor base update;
          in
            if context.scope != "wasix"
            then throw "${name}: exposeWasixExtendedPackages is only valid in a WASIX package set"
            else candidate
      )
      updates;
    exposeExtendedPackages = updates:
      lib.mapAttrs (
        resultName: update:
          if !(builtins.hasAttr resultName previousSet)
          then throw "${name}: exposeExtendedPackages requires preceding package '${resultName}'"
          else if builtins.isFunction update
          then update previousSet.${resultName}
          else extendPackageFor previousSet.${resultName} update
      )
      updates;
    value =
      callWithLabel "package unit ${toString file}" (
        context
        // {
          inherit exposeExtendedPackage exposeExtendedPackages exposeNativePackage exposePackage exposePackageVariants exposeWasixExtendedPackage exposeWasixExtendedPackages exposeWasixPackage;
        }
        // lib.optionalAttrs previousAvailable {package = previous;}
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

  discoverShardedUnits = {
    dir,
    lane,
  }: let
    rootEntries = builtins.readDir dir;
    rootFiles = lib.attrNames (lib.filterAttrs (_: type: type == "regular") rootEntries);
    invalidRootFiles = lib.filter (name: name != "history.json") rootFiles;
    buckets = lib.attrNames (lib.filterAttrs (_: type: type == "directory") rootEntries);
    invalidBuckets = lib.filter (name: builtins.match "[a-z0-9]" name == null) buckets;
    unitsForBucket = bucket: let
      bucketDir = dir + "/${bucket}";
      entries = builtins.readDir bucketDir;
      regularFiles = lib.attrNames (lib.filterAttrs (_: type: type == "regular") entries);
      invalidFiles = lib.filter (name: !lib.hasSuffix ".nix" name) regularFiles;
      flatUnits =
        map (fileName: {
          name = lib.removeSuffix ".nix" fileName;
          directory = null;
          file = bucketDir + "/${fileName}";
          kind =
            if lane == "packages"
            then "wasix"
            else "package";
        })
        regularFiles;
      directoryNames = lib.attrNames (lib.filterAttrs (_: type: type == "directory") entries);
      stateFor = name: let
        directory = bucketDir + "/${name}";
      in {
        inherit directory name;
        package = builtins.pathExists (directory + "/package.nix");
        recipe = builtins.pathExists (directory + "/recipe.nix");
        wasix = builtins.pathExists (directory + "/wasix.nix");
      };
      states = map stateFor directoryNames;
      conflicts = lib.filter (state: state.package && state.wasix) states;
      recipes = lib.filter (state: state.recipe) states;
      invalidWasix = lib.filter (state: lane == "python" && state.wasix) states;
      missing = lib.filter (state: !state.package && !state.wasix && !state.recipe) states;
      directoryUnits = map (state: {
        inherit (state) directory name;
        file =
          state.directory
          + (
            if state.package
            then "/package.nix"
            else "/wasix.nix"
          );
        kind =
          if state.package
          then "package"
          else "wasix";
      }) (lib.filter (state: state.package || state.wasix) states);
      flatConflicts = lib.intersectLists (map (unit: unit.name) flatUnits) (map (unit: unit.name) directoryUnits);
      names = values: lib.concatStringsSep ", " (map (value: value.name) values);
    in
      lib.throwIf (invalidFiles != [])
      "inventory ${toString dir} has loose support file(s) in bucket '${bucket}': ${lib.concatStringsSep ", " invalidFiles}"
      (lib.throwIf (conflicts != [])
        "inventory ${toString dir} has entries containing both package.nix and wasix.nix: ${names conflicts}"
        (lib.throwIf (recipes != [])
          "inventory ${toString dir} contains obsolete recipe.nix entries: ${names recipes}"
          (lib.throwIf (invalidWasix != [])
            "Python inventory ${toString dir} contains wasix.nix entries: ${names invalidWasix}"
            (lib.throwIf (missing != [])
              "inventory ${toString dir} has directories without an entry file: ${names missing}"
              (lib.throwIf (flatConflicts != [])
                "inventory ${toString dir} defines both flat and directory entries: ${lib.concatStringsSep ", " flatConflicts}"
                (flatUnits ++ directoryUnits))))));
    units = lib.concatMap unitsForBucket buckets;
    misplaced = lib.filter (unit: let
      relative = lib.removePrefix (toString dir + "/") (toString unit.file);
    in
      lib.substring 0 1 unit.name != lib.substring 0 1 relative)
    units;
  in
    lib.throwIf (invalidRootFiles != [])
    "inventory ${toString dir} has loose root file(s): ${lib.concatStringsSep ", " invalidRootFiles}"
    (lib.throwIf (invalidBuckets != [])
      "inventory ${toString dir} has invalid bucket(s): ${lib.concatStringsSep ", " invalidBuckets}"
      (lib.throwIf (misplaced != [])
        "inventory ${toString dir} has entries in the wrong bucket: ${lib.concatStringsSep ", " (map (unit: unit.name) misplaced)}"
        units));

  mergeDisjoint = state: unit: let
    duplicate = lib.intersectLists (lib.attrNames state) (lib.attrNames unit);
  in
    lib.throwIf (duplicate != [])
    "package units define duplicate attribute(s): ${lib.concatStringsSep ", " duplicate}"
    (state // unit);

  packageMetadata = package: (package.passthru or {}).wasinix or {};

  packageForEntry = packages: entry: let
    current = packages.sameProfile.${entry.name};
  in
    if entry.instance.kind == "history"
    then current.versions.${entry.instance.version}
    else current;

  addressSegment = segment:
    if builtins.match "[A-Za-z_][A-Za-z0-9_'-]*" segment != null
    then ".${segment}"
    else ".${builtins.toJSON segment}";

  address = root: segments:
    root + lib.concatMapStrings addressSegment segments;

  loadPackageOverlays = directories:
    lib.mapAttrs (_: declaration:
      {
        __wasinixPackageDirectory = true;
      }
      // (
        if lib.isAttrs declaration
        then declaration
        else {directory = declaration;}
      ))
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
                removeAttrs metadata machineMetadata
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
  inherit address addressSegment buildHostPypaTools callWith callWithLabel discoverShardedUnits dropFlagsByPrefix dropInputsByName dropInputsByNameInfix dropPatchesByNameInfix dropSphinxDocs extendAttrs extendPythonPackage extensionContextsAttr historyBaseAttr historyOverlaysAttr linkInputs loadPackageOverlays loadTestDirectory machineMetadata mergeScript packageForEntry packageMetadata registryAttr replaceInputsByName stampPackage unitOverlaysAttr unitResult wasmRename;

  inherit extendPackage;

  loadPackageOverlay = {
    contextFor,
    definition ? null,
    dir,
    extendPackageFor ? extendPackage,
    expose ? [],
    inherited ? {},
    lane ? "packages",
    scope ? null,
  }: final: prev: let
    formalsFor = unit: builtins.functionArgs (import unit.file);
    instantiatePackage = unit: final': prev': let
      formals = formalsFor unit;
      context = contextFor {
        final = final';
        prev = prev';
      };
      nativeOnly = formals ? exposeNativePackage;
      requestsPrevious =
        formals ? package
        || formals ? exposeExtendedPackage
        || formals ? exposeWasixExtendedPackage
        || formals ? exposeWasixExtendedPackages
        || formals ? exposeWasixPackage;
      previousAvailable = builtins.hasAttr unit.name prev';
    in
      if scope == "wasix" && nativeOnly
      then {
        ${unit.name} = withoutMachineMetadata context.packages.native.${unit.name};
      }
      else
        unitResult {
          inherit (unit) file name;
          inherit extendPackageFor context;
          previous =
            if requestsPrevious && previousAvailable
            then builtins.addErrorContext "while resolving the preceding package for ${toString unit.file}\n" (prev'.${unit.name} or null)
            else null;
          inherit previousAvailable;
          previousRegistered = builtins.hasAttr unit.name (prev'.${registryAttr} or {});
          previousSet = prev';
        };
    instantiate = instantiatePackage;
    discoveredUnits = discoverShardedUnits {inherit dir lane;};
    inheritedDeclarations =
      lib.throwIf (!lib.isAttrs inherited || lib.isDerivation inherited)
      "package directory ${toString dir} has a non-attribute inherited declaration"
      inherited;
    inheritedDeclarationNames = lib.attrNames inheritedDeclarations;
    invalidInheritedDeclarations = lib.attrNames (lib.filterAttrs (_: value: !lib.isAttrs value || lib.isDerivation value) inheritedDeclarations);
    inheritedUnitConflicts = lib.intersectLists inheritedDeclarationNames (map (unit: unit.name) discoveredUnits);
    inheritedResult = previous: name:
      if !(builtins.hasAttr name previous)
      then throw "${name}: inherited package requires a preceding package"
      else {
        ${name} = previous.${name}.overrideAttrs (old: {
          passthru =
            (old.passthru or {})
            // {
              wasix = ((old.passthru or {}).wasix or {}) // inheritedDeclarations.${name};
            };
        });
      };
    inheritedResults =
      lib.optionals (prev.stdenv.hostPlatform.isWasix or false)
      (map (name: {
          kind = "inherited";
          inherit definition;
          result = inheritedResult prev name;
          replay = _final: previous: inheritedResult previous name;
        })
        inheritedDeclarationNames);
    units =
      lib.filter (
        unit: let
          wrongHost = unit.kind == "wasix" && !(prev.stdenv.hostPlatform.isWasix or false);
        in
          !(lane == "packages" && wrongHost)
      )
      discoveredUnits;
    discoveredResults =
      map (unit: {
        inherit (unit) kind;
        definition = {
          inherit (unit) directory file;
        };
        result = instantiate unit final prev;
        replay = instantiate unit;
      })
      units;
    results = inheritedResults ++ discoveredResults;
    packages = builtins.foldl' mergeDisjoint {} (map (item: item.result) results);
    completeNames = lib.concatMap (item: lib.optionals (item.kind == "package") (lib.attrNames item.result)) results;
    precedingNames = lib.subtractLists (lib.attrNames packages) (expose ++ completeNames);
    missingPreceding = lib.filter (name: !(builtins.hasAttr name prev)) precedingNames;
    preceding = lib.genAttrs precedingNames (name: prev.${name});
    unitOverlays = builtins.foldl' (state: item:
      state
      // lib.genAttrs (lib.attrNames item.result) (_: {
        inherit (item) definition;
        overlay = item.replay;
      })) {}
    results;
  in
    lib.throwIf (invalidInheritedDeclarations != [])
    "package directory ${toString dir} has invalid inherited declaration(s): ${lib.concatStringsSep ", " invalidInheritedDeclarations}"
    (lib.throwIf (inheritedUnitConflicts != [])
      "package directory ${toString dir} declares inherited package unit(s): ${lib.concatStringsSep ", " inheritedUnitConflicts}"
      (lib.throwIf (missingPreceding != [])
        "package directory ${toString dir} exposes missing preceding package(s): ${lib.concatStringsSep ", " missingPreceding}"
        (preceding // packages // {${unitOverlaysAttr} = unitOverlays;})));

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
      visibleResult = removeAttrs result [unitOverlaysAttr];
      reserved = lib.intersectLists (lib.attrNames result) [registryAttr extensionContextsAttr];
      names = removeAttrs (lib.genAttrs (lib.attrNames visibleResult) (_: source)) [registryAttr extensionContextsAttr];
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
                previous =
                  if builtins.hasAttr name (prev.${registryAttr} or {})
                  then prev.${name}
                  else null;
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

  packageAddressesForSource = entries: source:
    lib.attrNames (lib.filterAttrs (_: entry:
      entry.kind == "package" && entry.source == source)
    entries);

  entriesForSource = entries: source: let
    packageAddresses = packageAddressesForSource entries source;
  in
    lib.filterAttrs (_: entry:
      entry.source
      == source
      || lib.intersectLists (entry.packageSubjects or []) packageAddresses != [])
    entries;
}
