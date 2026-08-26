{
  lib,
  mkPythonRegistry,
  mkPythonWheels,
}: let
  wheelList = import ../python/wheels/default.nix;
  history = builtins.fromJSON (builtins.readFile ../python-overlays/history.json);
  wheelInventory = lib.listToAttrs (map (entry: lib.nameValuePair entry.attr entry) wheelList);
  wheelArtifactKind = variant: "wheel-${variant}";
  isNoarch = entry: entry.noarch or false;
  wheelSet = {
    interpreter,
    packages,
    packageSets,
    pythonVariants,
    pyKey,
    select,
  }: let
    pythonName = pythonVariants.specs.${interpreter}.interpreterPackage;
    python = packageSets.wasix.preferred.${pythonName};
    pythonArtifact = packages.wasix.preferred.${pythonName};
  in
    mkPythonWheels {
      inherit pyKey select;
      interpreterVariants = pythonVariants.all;
      python3 = python;
      pythonPackages =
        packageSets.python.${interpreter}
        // {inherit (python.pkgs) requiredPythonModules;};
      packageVersions = lib.mapAttrs (_: package: package.versions or {}) packages.python.${interpreter};
      pythonWebc = pythonArtifact.artifacts.webc;
    };

  flattenTests = prefix: tests:
    lib.concatMapAttrs (name: value: let
      path = lib.optionalString (prefix != "") "${prefix}-" + name;
    in
      if builtins.elem name ["all" "passthru"]
      then {}
      else if lib.isDerivation value
      then {${path} = value;}
      else if lib.isAttrs value
      then flattenTests path value
      else throw "artifact test '${path}' is neither a derivation nor an attribute set")
    tests;
  wheelsFor = packages: interpreter: kind:
    lib.concatMapAttrs (name: package:
      lib.optionalAttrs (package.artifacts ? ${kind}) {
        ${name} = package.artifacts.${kind};
      }
      // lib.concatMapAttrs (version: retained:
        lib.optionalAttrs (retained.artifacts ? ${kind}) {
          "${name}-${version}" = retained.artifacts.${kind};
        })
      package.versions)
    packages.python.${interpreter};
in {
  wheelArtifacts = {
    entry,
    packages,
    packageSets,
    pythonVariants,
    ...
  }: let
    declaration = wheelInventory.${entry.name} or null;
    noarch = declaration != null && isNoarch declaration;
    interpreter = entry.variant.interpreter or null;
    pyKey =
      if noarch
      then "noarch"
      else interpreter;
    instanceVariants =
      if entry.instance.kind == "history"
      then history.${entry.name}.${entry.instance.version}.variants or pythonVariants.all
      else declaration.variants or pythonVariants.all;
    enabled =
      declaration
      != null
      && entry.kind == "package"
      && entry.scope == "python"
      && (
        if noarch
        then interpreter == pythonVariants.preferred
        else builtins.elem interpreter instanceVariants
      );
    wheels = wheelSet {
      inherit packages packageSets pythonVariants pyKey;
      interpreter =
        if noarch
        then pythonVariants.preferred
        else interpreter;
      select = candidate: candidate.attr == entry.name;
    };
    wheelName =
      if entry.instance.kind == "history"
      then "${entry.name}-${entry.instance.version}"
      else entry.name;
  in
    lib.optionalAttrs enabled {
      artifacts.${wheelArtifactKind pyKey} = wheels.${wheelName};
    };

  registryArtifact = {
    catalog,
    packages,
    packageSets,
    pythonVariants,
    ...
  }: let
    inherit (pythonVariants) preferred;
    preferredPython = pythonVariants.specs.${preferred}.interpreterPackage;
    publishOnce = map (entry': entry'.attr) (lib.filter (entry': entry'.publishOnce or false) wheelList);
    pythonSets =
      lib.mapAttrs (interpreter: spec: {
        python3 = packageSets.wasix.preferred.${spec.interpreterPackage};
        pythonWheels =
          wheelsFor packages interpreter (wheelArtifactKind interpreter)
          // lib.optionalAttrs (interpreter == preferred) (wheelsFor packages interpreter "wheel-noarch");
        omitFromRegistry = lib.optionals (interpreter != preferred) publishOnce;
      })
      pythonVariants.specs;
    wheelArtifactKinds = map wheelArtifactKind (pythonVariants.all ++ ["noarch"]);
    wheelSubjects = map (entry: entry.address) (lib.filter (entry:
      entry.kind
      == "artifact"
      && builtins.elem entry.artifactKind wheelArtifactKinds)
    (builtins.attrValues catalog.entries));
    registry = mkPythonRegistry {
      python3 = packageSets.wasix.preferred.${preferredPython};
      pythonWebc = packages.wasix.preferred.${preferredPython}.artifacts.webc.shim;
      inherit pythonSets;
    };
  in {
    artifacts.registry.python = {
      artifact = registry;
      subjects = wheelSubjects;
      scope = "python";
      variant.interpreter = preferred;
    };
  };

  artifactTests = {
    entry,
    pythonVariants,
    ...
  }:
    lib.optionalAttrs (
      entry.kind
      == "artifact"
      && builtins.elem entry.artifactKind (["registry"] ++ map wheelArtifactKind (pythonVariants.all ++ ["noarch"]))
      && (entry.artifact.passthru or {}) ? tests
    ) {
      tests = flattenTests "" entry.artifact.passthru.tests;
    };
}
