{lib}: let
  registryAttr = "__wasinixRegisteredPackages";
  compatibilityAttr = "__wasinixPackageCompatibility";
  ciPackageAttr = "__wasinixCiPackages";
  identityAttr = "__wasinixPackageIdentities";
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

  unitResult = {
    context,
    extendPackageFor ? extendPackage,
    file,
    name,
    previous ? null,
    previousAvailable ? previous != null,
    previousRegistered ? false,
    previousSet ? {},
  }: let
    function = import file;
    cleanMachineMetadata = package:
      package.overrideAttrs (old: {
        passthru =
          (old.passthru or {})
          // {
            wasinix = removeAttrs ((old.passthru or {}).wasinix or {}) machineMetadata;
          };
      });
    exposeNamedPackage = resultName: package:
      if !lib.isDerivation package
      then throw "package unit ${toString file} exposed non-derivation attribute '${resultName}'"
      else if resultName == name && previousRegistered
      then package
      else cleanMachineMetadata package;
    exposePackage = package: {${name} = exposeNamedPackage name package;};
    exposePackageIdentity = {
      package,
      wasix ? ((package.passthru or {}).wasix or {}),
    }: {
      ${compatibilityAttr}.${name} = wasix;
      ${identityAttr}.${name} = cleanMachineMetadata package;
    };
    exposeNativePackage = package:
      if (context.scope or "native") == "wasix"
      then {}
      else exposePackage package;
    exposeNativePackageIdentity = args:
      if (context.scope or "native") == "wasix"
      then {}
      else
        exposePackageIdentity args
        // {${ciPackageAttr}.${name} = false;};
    exposeExtendedPackage = attrs:
      if !previousAvailable
      then throw "${name}: exposeExtendedPackage requires a preceding package"
      else
        exposePackage (
          builtins.addErrorContext "while extending the preceding package for ${toString file}\n"
          (extendPackageFor previous attrs)
        );
    exposeNativeExtendedPackage = attrs:
      if (context.scope or "native") == "wasix"
      then {}
      else exposeExtendedPackage attrs;
    exposePackages = names:
      if (context.scope or "native") == "wasix"
      then {}
      else {
        ${ciPackageAttr} = lib.genAttrs names (_resultName: false);
        ${identityAttr} = lib.genAttrs names (resultName:
          if !(builtins.hasAttr resultName previousSet)
          then throw "${name}: exposePackages requires preceding package '${resultName}'"
          else cleanMachineMetadata previousSet.${resultName});
      };
    exposePackagesWithWasix = declarations:
      if (context.scope or "native") == "wasix"
      then {}
      else {
        ${ciPackageAttr} = lib.mapAttrs (_resultName: _declaration: false) declarations;
        ${compatibilityAttr} = declarations;
      };
    exposeWasixPackage = package:
      if (context.scope or "native") == "wasix"
      then exposePackage package
      else {};
    exposeWasixExtendedPackage = attrs:
      if !previousAvailable
      then throw "${name}: exposeWasixExtendedPackage requires a preceding package"
      else let
        package = extendPackageFor previous attrs;
      in
        exposePackage (
          if (context.scope or "native") == "wasix"
          then package
          else previous
        );
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
    exposeExtendedPackageIdentities = updates: {
      ${identityAttr} =
        lib.mapAttrs (
          resultName: update:
            if !(builtins.hasAttr resultName previousSet)
            then throw "${name}: exposeExtendedPackageIdentities requires preceding package '${resultName}'"
            else
              cleanMachineMetadata (
                if builtins.isFunction update
                then update previousSet.${resultName}
                else extendPackageFor previousSet.${resultName} update
              )
        )
        updates;
    };
    exposeWasixExtendedPackages = updates:
      lib.mapAttrs (
        resultName: update:
          if !(builtins.hasAttr resultName previousSet)
          then throw "${name}: exposeWasixExtendedPackages requires preceding package '${resultName}'"
          else let
            base = previousSet.${resultName};
            package =
              if builtins.isFunction update
              then update base
              else extendPackageFor base update;
          in
            if (context.scope or "native") == "wasix"
            then package
            else base
      )
      updates;
    value =
      callWithLabel "package unit ${toString file}" (
        context
        // {
          inherit exposeExtendedPackage exposeExtendedPackageIdentities exposeExtendedPackages exposeNativeExtendedPackage exposeNativePackage exposeNativePackageIdentity exposePackage exposePackageIdentity exposePackages exposePackagesWithWasix exposeWasixExtendedPackage exposeWasixExtendedPackages exposeWasixPackage;
        }
        // lib.optionalAttrs previousAvailable {package = previous;}
      )
      function;
    visibleValue = removeAttrs value [compatibilityAttr ciPackageAttr identityAttr];
    packages =
      lib.mapAttrs (
        resultName: package:
          lib.throwIf (!lib.isDerivation package)
          "package unit ${toString file} returned non-derivation attribute '${resultName}'"
          package
      )
      visibleValue;
    result =
      packages
      // lib.optionalAttrs (value ? ${compatibilityAttr}) {${compatibilityAttr} = value.${compatibilityAttr};}
      // lib.optionalAttrs (value ? ${ciPackageAttr}) {${ciPackageAttr} = value.${ciPackageAttr};}
      // lib.optionalAttrs (value ? ${identityAttr}) {${identityAttr} = value.${identityAttr};};
  in
    lib.throwIf (!builtins.isFunction function)
    "package unit ${toString file} must be a function"
    (lib.throwIf (lib.isDerivation value)
      "package unit ${toString file} returned a bare derivation; use exposePackage"
      (lib.throwIf (!lib.isAttrs value)
        "package unit ${toString file} must return an attribute set of derivations"
        result));

  discoverUnits = dir: let
    entries = builtins.readDir dir;
    files =
      map (name: {
        inherit name;
        directory = null;
        file = dir + "/${name}.nix";
        kind = "package";
      })
      (lib.filter (name: name != "default" && name != "history")
        (map (lib.removeSuffix ".nix")
          (lib.attrNames (lib.filterAttrs (name: type: type == "regular" && lib.hasSuffix ".nix" name) entries))));
    directoryNames = lib.attrNames (lib.filterAttrs (_: type: type == "directory") entries);
    recipes = lib.filter (name: builtins.pathExists (dir + "/${name}/recipe.nix")) directoryNames;
    directories = lib.concatMap (name: let
      packageFile = dir + "/${name}/package.nix";
    in
      lib.optional (builtins.pathExists packageFile) {
        inherit name;
        directory = dir + "/${name}";
        file = packageFile;
        kind = "package";
      })
    directoryNames;
  in
    lib.throwIf (recipes != [])
    "package inventory ${toString dir} contains obsolete recipe.nix entries: ${lib.concatStringsSep ", " recipes}"
    (files ++ directories);

  discoverShardedInventory = {
    dir,
    lane,
  }: let
    entries = builtins.readDir dir;
    buckets = lib.attrNames (lib.filterAttrs (_: type: type == "directory") entries);
    invalidBuckets = lib.filter (bucket: builtins.match "[a-z0-9]" bucket == null) buckets;
    discoverBucket = bucket: let
      bucketDir = dir + "/${bucket}";
      bucketEntries = builtins.readDir bucketDir;
      regularNames = lib.attrNames (lib.filterAttrs (_name: type: type == "regular") bucketEntries);
      invalidFiles = lib.filter (name: !lib.hasSuffix ".nix" name) regularNames;
      files = map (name: {
        inherit name;
        directory = null;
        file = bucketDir + "/${name}.nix";
        specializationFile =
          if lane == "packages"
          then bucketDir + "/${name}.nix"
          else null;
        kind =
          if lane == "packages"
          then "wasix"
          else "package";
      }) (map (lib.removeSuffix ".nix") (lib.filter (lib.hasSuffix ".nix") regularNames));
      directoryNames = lib.attrNames (lib.filterAttrs (_name: type: type == "directory") bucketEntries);
      directoryState = name: let
        directory = bucketDir + "/${name}";
        packageFile = directory + "/package.nix";
        wasixFile = directory + "/wasix.nix";
        recipeFile = directory + "/recipe.nix";
        hasPackage = builtins.pathExists packageFile;
        hasWasix = builtins.pathExists wasixFile;
        hasRecipe = builtins.pathExists recipeFile;
      in {
        inherit directory hasPackage hasRecipe hasWasix name packageFile recipeFile wasixFile;
      };
      states = map directoryState directoryNames;
      recipes = lib.filter (state: state.hasRecipe) states;
      invalidWasix = lib.filter (state: lane == "python" && state.hasWasix) states;
      missing = lib.filter (state: !state.hasPackage && !state.hasWasix && !state.hasRecipe) states;
      directories = map (state: {
        inherit (state) directory name;
        file =
          if state.hasPackage
          then state.packageFile
          else state.wasixFile;
        kind =
          if state.hasPackage
          then "package"
          else "wasix";
        specializationFile =
          if state.hasWasix
          then state.wasixFile
          else null;
      }) (lib.filter (state: state.hasPackage || state.hasWasix) states);
      flatNames = map (unit: unit.name) files;
      directoryNames' = map (unit: unit.name) directories;
      flatConflicts = lib.intersectLists flatNames directoryNames';
      names = values: lib.concatStringsSep ", " (map (value: value.name) values);
    in
      lib.throwIf (invalidFiles != [])
      "inventory bucket ${toString bucketDir} contains non-Nix file(s): ${lib.concatStringsSep ", " invalidFiles}"
      (lib.throwIf (recipes != [])
        "inventory ${toString dir} contains obsolete recipe.nix entries: ${names recipes}"
        (lib.throwIf (invalidWasix != [])
          "Python inventory ${toString dir} contains wasix.nix entries: ${names invalidWasix}"
          (lib.throwIf (missing != [])
            "inventory ${toString dir} has directories without an entry file: ${names missing}"
            (lib.throwIf (flatConflicts != [])
              "inventory ${toString dir} defines both flat and directory entries: ${lib.concatStringsSep ", " flatConflicts}"
              (files ++ directories)))));
    unitsByBucket = lib.genAttrs buckets discoverBucket;
    misplaced = lib.concatMap (bucket:
      map (unit: "${bucket}/${unit.name}")
      (lib.filter (unit: lib.substring 0 1 unit.name != bucket) unitsByBucket.${bucket}))
    buckets;
    units = lib.concatMap (bucket: unitsByBucket.${bucket}) buckets;
    grouped = lib.groupBy (unit: unit.name) units;
    duplicates = lib.attrNames (lib.filterAttrs (_: values: lib.length values > 1) grouped);
  in
    lib.throwIf (invalidBuckets != [])
    "inventory ${toString dir} has invalid bucket(s): ${lib.concatStringsSep ", " invalidBuckets}"
    (lib.throwIf (misplaced != [])
      "inventory ${toString dir} has entries in the wrong bucket: ${lib.concatStringsSep ", " misplaced}"
      (lib.throwIf (duplicates != [])
        "inventory ${toString dir} defines duplicate package name(s): ${lib.concatStringsSep ", " duplicates}"
        {inherit units;}));

  mergeDisjoint = state: unit: let
    stateCompatibility = state.${compatibilityAttr} or {};
    unitCompatibility = unit.${compatibilityAttr} or {};
    stateCiPackages = state.${ciPackageAttr} or {};
    unitCiPackages = unit.${ciPackageAttr} or {};
    stateIdentities = state.${identityAttr} or {};
    unitIdentities = unit.${identityAttr} or {};
    statePackages = removeAttrs state [compatibilityAttr ciPackageAttr identityAttr];
    unitPackages = removeAttrs unit [compatibilityAttr ciPackageAttr identityAttr];
    duplicate = lib.intersectLists (lib.attrNames statePackages) (lib.attrNames unitPackages);
    duplicateCompatibility = lib.intersectLists (lib.attrNames stateCompatibility) (lib.attrNames unitCompatibility);
    duplicateIdentities = lib.intersectLists (lib.attrNames stateIdentities) (lib.attrNames unitIdentities);
  in
    lib.throwIf (duplicate != [])
    "package units define duplicate attribute(s): ${lib.concatStringsSep ", " duplicate}"
    (lib.throwIf (duplicateCompatibility != [])
      "package units define duplicate compatibility for: ${lib.concatStringsSep ", " duplicateCompatibility}"
      (lib.throwIf (duplicateIdentities != [])
        "package units define duplicate identities for: ${lib.concatStringsSep ", " duplicateIdentities}"
        (statePackages
          // unitPackages
          // lib.optionalAttrs (stateCompatibility != {} || unitCompatibility != {}) {
            ${compatibilityAttr} = stateCompatibility // unitCompatibility;
          }
          // lib.optionalAttrs (stateIdentities != {} || unitIdentities != {}) {
            ${identityAttr} = stateIdentities // unitIdentities;
          }
          // lib.optionalAttrs (stateCiPackages != {} || unitCiPackages != {}) {
            ${ciPackageAttr} = stateCiPackages // unitCiPackages;
          })));

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
  inherit address addressSegment buildHostPypaTools callWith callWithLabel ciPackageAttr compatibilityAttr discoverShardedInventory discoverUnits dropFlagsByPrefix dropInputsByName dropInputsByNameInfix dropPatchesByNameInfix dropSphinxDocs extendAttrs extendPythonPackage extensionContextsAttr historyBaseAttr historyOverlaysAttr identityAttr linkInputs loadPackageOverlays loadTestDirectory machineMetadata mergeScript packageForEntry packageMetadata registryAttr replaceInputsByName stampPackage unitOverlaysAttr unitResult wasmRename;

  inherit extendPackage;

  loadPackageOverlay = {
    contextFor,
    definition ? null,
    dir,
    extendPackageFor ? extendPackage,
    expose ? [],
    inherited ? {},
    part ? "all",
    selectUnit ? _name: true,
    sharded ? false,
    scope ? "native",
  }: final: prev: let
    inventory =
      if sharded
      then
        discoverShardedInventory {
          inherit dir;
          lane =
            if scope == "python"
            then "python"
            else "packages";
        }
      else {
        units = discoverUnits dir;
        directories =
          lib.mapAttrsToList (name: _type: {
            inherit name;
            directory = dir + "/${name}";
          })
          (lib.filterAttrs (_: type: type == "directory") (builtins.readDir dir));
      };
    instantiatePackage = unit: final': prev': let
      formals = builtins.functionArgs (import unit.file);
      requestsPrevious =
        formals ? package
        || formals ? exposeExtendedPackage
        || formals ? exposeExtendedPackageIdentities
        || formals ? exposeNativeExtendedPackage
        || formals ? exposePackages
        || formals ? exposePackagesWithWasix
        || formals ? exposeWasixPackage
        || formals ? exposeWasixExtendedPackage;
      previousAvailable = builtins.hasAttr unit.name prev';
    in
      unitResult {
        inherit (unit) file name;
        inherit extendPackageFor;
        context = contextFor {
          final = final';
          prev = prev';
        };
        previous =
          if requestsPrevious && previousAvailable
          then builtins.addErrorContext "while resolving the preceding package for ${toString unit.file}\n" (prev'.${unit.name} or null)
          else null;
        inherit previousAvailable;
        previousRegistered = builtins.hasAttr unit.name (prev'.${registryAttr} or {});
        previousSet = prev';
      };
    instantiate = instantiatePackage;
    inheritedDeclarations =
      lib.throwIf (!lib.isAttrs inherited || lib.isDerivation inherited)
      "package directory ${toString dir} has a non-attribute inherited declaration"
      inherited;
    inheritedDeclarationNames = lib.attrNames inheritedDeclarations;
    selectedInheritedNames = lib.filter selectUnit inheritedDeclarationNames;
    invalidInheritedDeclarations = lib.attrNames (lib.filterAttrs (_: value: !lib.isAttrs value || lib.isDerivation value) inheritedDeclarations);
    inheritedResult = previous: name:
      if !(builtins.hasAttr name previous)
      then throw "${name}: inherited package requires a preceding package"
      else let
        package = previous.${name}.overrideAttrs (old: {
          passthru =
            (old.passthru or {})
            // {
              wasix = ((old.passthru or {}).wasix or {}) // inheritedDeclarations.${name};
            };
        });
      in
        if scope == "wasix"
        then {${name} = package;}
        else {
          ${compatibilityAttr}.${name} = inheritedDeclarations.${name};
          ${ciPackageAttr}.${name} = false;
          ${identityAttr}.${name} = package;
        };
    inheritedResults =
      map (name: {
        kind = "inherited";
        inherit definition;
        result = inheritedResult prev name;
        replay = _final: previous: inheritedResult previous name;
      })
      selectedInheritedNames;
    instantiateResults = previous: units:
      map (unit: {
        inherit (unit) kind;
        definition = {
          inherit (unit) directory file;
        };
        result = instantiate unit final previous;
        replay = instantiate unit;
      })
      units;
    discoveredUnits =
      if part == "wasix"
      then []
      else
        lib.filter (unit:
          selectUnit unit.name
          && (
            if sharded
            then unit.kind == "package"
            else
              scope
              != "wasix"
              || unit.kind == "package"
              || (unit.directory != null && builtins.pathExists (unit.directory + "/wasix.nix"))
          ))
        inventory.units;
    discoveredNames = map (unit: unit.name) discoveredUnits;
    implicitUnits =
      if sharded
      then
        map (unit: {
          inherit (unit) name directory;
        })
        (lib.filter (unit: selectUnit unit.name && unit.kind == "wasix") inventory.units)
      else
        map (entry: {
          inherit (entry) name directory;
          file = entry.directory + "/wasix.nix";
          kind = "implicit";
        })
        (lib.filter (entry:
          selectUnit entry.name
          && !(builtins.elem entry.name discoveredNames)
          && builtins.pathExists (entry.directory + "/wasix.nix"))
        inventory.directories);
    units = discoveredUnits;
    inheritedUnitConflicts = lib.intersectLists inheritedDeclarationNames (map (unit: unit.name) inventory.units);
    baseResults = inheritedResults ++ instantiateResults prev units;
    basePackages = builtins.foldl' mergeDisjoint {} (map (item: item.result) baseResults);
    wasixUnits =
      if scope != "wasix" || part == "base"
      then []
      else if sharded
      then
        map (unit: {
          inherit (unit) name directory;
          file = unit.specializationFile;
          kind = "package";
        })
        (lib.filter (unit: selectUnit unit.name && unit.specializationFile != null) inventory.units)
      else
        map (entry: {
          inherit (entry) name directory;
          file = entry.directory + "/wasix.nix";
          kind = "package";
        })
        (lib.filter (entry:
          selectUnit entry.name
          && builtins.pathExists (entry.directory + "/wasix.nix"))
        inventory.directories);
    specializationResults = instantiateResults (prev // basePackages) wasixUnits;
    specializationPackages = builtins.foldl' mergeDisjoint {} (map (item: item.result) specializationResults);
    results = baseResults ++ specializationResults;
    compatibility = (basePackages.${compatibilityAttr} or {}) // (specializationPackages.${compatibilityAttr} or {});
    declaredCiPackages = (basePackages.${ciPackageAttr} or {}) // (specializationPackages.${ciPackageAttr} or {});
    declaredIdentities = (basePackages.${identityAttr} or {}) // (specializationPackages.${identityAttr} or {});
    packages = removeAttrs (basePackages // specializationPackages) [compatibilityAttr ciPackageAttr identityAttr];
    precedingNames = lib.subtractLists (lib.attrNames packages) expose;
    missingPreceding = lib.filter (name: !(builtins.hasAttr name prev)) precedingNames;
    preceding = lib.genAttrs precedingNames (name: prev.${name});
    implicitIdentityUnits = lib.filter (unit: builtins.hasAttr unit.name prev) implicitUnits;
    implicitIdentities =
      if scope != "native"
      then {}
      else lib.genAttrs (map (unit: unit.name) implicitIdentityUnits) (name: prev.${name});
    ciPackages =
      declaredCiPackages
      // lib.optionalAttrs (scope == "native") (lib.genAttrs (map (unit: unit.name) implicitIdentityUnits) (_name: false));
    identities = declaredIdentities // implicitIdentities;
    unitOverlays = builtins.foldl' (state: item: let
      identityNames = lib.attrNames (item.result.${identityAttr} or {});
      resultNames = lib.attrNames (removeAttrs item.result [compatibilityAttr ciPackageAttr identityAttr]) ++ identityNames;
      replay = final': prev': let
        replayed = item.replay final' prev';
      in
        removeAttrs replayed [compatibilityAttr ciPackageAttr identityAttr]
        // lib.genAttrs identityNames (name: replayed.${identityAttr}.${name});
    in
      state
      // lib.genAttrs resultNames (name: let
        preceding = state.${name} or null;
      in {
        inherit (item) definition;
        overlay =
          if preceding == null
          then replay
          else
            final': prev': let
              base = preceding.overlay final' prev';
            in
              replay final' (prev' // base);
      })) {}
    results;
  in
    lib.throwIf (invalidInheritedDeclarations != [])
    "package directory ${toString dir} has invalid inherited declaration(s): ${lib.concatStringsSep ", " invalidInheritedDeclarations}"
    (lib.throwIf (inheritedUnitConflicts != [])
      "package directory ${toString dir} declares inherited package unit(s): ${lib.concatStringsSep ", " inheritedUnitConflicts}"
      (lib.throwIf (missingPreceding != [])
        "package directory ${toString dir} exposes missing preceding package(s): ${lib.concatStringsSep ", " missingPreceding}"
        (preceding
          // packages
          // {
            ${compatibilityAttr} = compatibility;
            ${ciPackageAttr} = ciPackages;
            ${identityAttr} = identities;
            ${unitOverlaysAttr} = unitOverlays;
          })));

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
      compatibility = result.${compatibilityAttr} or {};
      declaredCiPackages = result.${ciPackageAttr} or {};
      identities = result.${identityAttr} or {};
      unitOverlays = result.${unitOverlaysAttr} or {};
      visibleResult = removeAttrs result [compatibilityAttr ciPackageAttr identityAttr unitOverlaysAttr];
      reserved = lib.intersectLists (lib.attrNames result) [registryAttr extensionContextsAttr];
      identityNames = lib.unique (lib.attrNames identities ++ lib.attrNames compatibility);
      packageNames = lib.unique (lib.attrNames visibleResult ++ identityNames);
      invalidCiPackageNames = lib.subtractLists packageNames (lib.attrNames declaredCiPackages);
      invalidCiPackageValues = lib.attrNames (lib.filterAttrs (_name: value: !builtins.isBool value) declaredCiPackages);
      identityConflicts = lib.intersectLists identityNames (lib.attrNames (prev.${registryAttr} or {}));
      missingIdentities = lib.filter (name:
        !(builtins.hasAttr name prev)
        && !(builtins.hasAttr name visibleResult)
        && !(builtins.hasAttr name identities))
      identityNames;
      names = removeAttrs (lib.genAttrs packageNames (_: source)) [registryAttr extensionContextsAttr];
      ciPackages =
        (prev.${ciPackageAttr} or {})
        // lib.genAttrs packageNames (_name: true)
        // declaredCiPackages;
      stamped =
        lib.mapAttrs (
          name: value: let
            unit = unitOverlays.${name} or null;
          in
            lib.throwIf (!lib.isDerivation value)
            "registered overlay '${source}' returned non-derivation attribute '${name}'"
            (stampPackage {
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
            })
        )
        visibleResult;
      stampedIdentities =
        lib.mapAttrs (
          name: value: let
            unit = unitOverlays.${name} or null;
            previous =
              if builtins.hasAttr name (prev.${registryAttr} or {})
              then (prev.${identityAttr} or {}).${name} or prev.${name}
              else null;
          in
            stampPackage {
              inherit name previous source;
              definition =
                if unit == null
                then definition
                else unit.definition;
              package = value;
              previousSet = prev;
              overlay =
                if unit == null
                then overlay
                else unit.overlay;
              instance = instanceFor name value;
            }
        )
        identities;
    in
      lib.throwIf (reserved != [])
      "registered overlay '${source}' sets reserved attribute(s): ${lib.concatStringsSep ", " reserved}"
      (lib.throwIf (identityConflicts != [])
        "registered overlay '${source}' redeclares package identity attribute(s): ${lib.concatStringsSep ", " identityConflicts}"
        (lib.throwIf (invalidCiPackageNames != [])
          "registered overlay '${source}' declares CI policy for unknown package attribute(s): ${lib.concatStringsSep ", " invalidCiPackageNames}"
          (lib.throwIf (invalidCiPackageValues != [])
            "registered overlay '${source}' declares non-boolean CI package policy for: ${lib.concatStringsSep ", " invalidCiPackageValues}"
            (lib.throwIf (missingIdentities != [])
              "registered overlay '${source}' declares missing package identity attribute(s): ${lib.concatStringsSep ", " missingIdentities}"
              (stamped
                // {
                  ${compatibilityAttr} = (prev.${compatibilityAttr} or {}) // compatibility;
                  ${ciPackageAttr} = ciPackages;
                  ${identityAttr} = (prev.${identityAttr} or {}) // stampedIdentities;
                  ${registryAttr} = (prev.${registryAttr} or {}) // names;
                }))))));

  registeredNames = packageSet:
    lib.attrNames (packageSet.${registryAttr} or {});

  registeredPackages = packageSet: let
    names = registeredNames packageSet;
    identities = packageSet.${identityAttr} or {};
    registered = lib.genAttrs names (name: identities.${name} or packageSet.${name});
  in
    lib.filterAttrs (
      _: package:
        lib.isDerivation package
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
