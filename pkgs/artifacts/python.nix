{
  lib,
  mkPythonRegistry,
  mkPythonWheels,
}: let
  wheelList = import ../python/wheels/default.nix;
  history = builtins.fromJSON (builtins.readFile ../python/history.json);
  wheelInventory = lib.listToAttrs (map (entry: lib.nameValuePair entry.attr entry) wheelList);
  allVariants = ["py313" "py314" "noarch"];
  interpreterPackages = {
    py313 = "python313";
    py314 = "python314";
  };
  wheelArtifactKind = variant: "wheel-${variant}";
  wheelArtifactKinds = map wheelArtifactKind allVariants;
  isNoarch = entry: entry.noarch or false;
  pythonNameFor = interpreter:
    interpreterPackages.${interpreter}
    or (throw "unknown Python wheel interpreter '${interpreter}'");

  wheelSet = {
    interpreter,
    packages,
    packageSets,
    pyKey,
    select,
  }: let
    pythonName = pythonNameFor interpreter;
    python = packageSets.preferred.${pythonName};
    pythonArtifact = packages.preferred.${pythonName};
  in
    mkPythonWheels {
      inherit pyKey select;
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
      then history.${entry.name}.${entry.instance.version}.variants or ["py313" "py314"]
      else declaration.variants or allVariants;
    enabled =
      declaration
      != null
      && entry.kind == "package"
      && entry.scope == "python"
      && (
        if noarch
        then interpreter == "py314"
        else builtins.elem interpreter instanceVariants
      );
    wheels = wheelSet {
      inherit packages packageSets pyKey;
      interpreter =
        if noarch
        then "py314"
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
    entry,
    packages,
    packageSets,
    ...
  }:
    lib.optionalAttrs (
      entry.kind
      == "artifact"
      && entry.artifactKind == "webc"
      && entry.name == "python314"
      && entry.instance.kind == "current"
    ) (let
      noarch = wheelsFor packages "py314" "wheel-noarch";
      py313 = wheelsFor packages "py313" "wheel-py313";
      py314 = wheelsFor packages "py314" "wheel-py314";
      publishOnce = map (entry': entry'.attr) (lib.filter (entry': entry'.publishOnce or false) wheelList);
      registry = mkPythonRegistry {
        python3 = packageSets.preferred.python314;
        pythonWebc = entry.artifact;
        pythonSets = {
          py313 = {
            python3 = packageSets.preferred.python313;
            pythonWheels = py313;
            omitFromRegistry = publishOnce;
          };
          py314 = {
            python3 = packageSets.preferred.python314;
            pythonWheels = noarch // py314;
          };
        };
      };
    in {
      artifacts.registry = {
        artifact = registry;
        name = "python";
        projectionPath = ["python"];
      };
    });

  artifactTests = {entry, ...}:
    lib.optionalAttrs (
      entry.kind
      == "artifact"
      && builtins.elem entry.artifactKind (["registry"] ++ wheelArtifactKinds)
      && (entry.artifact.passthru or {}) ? tests
    ) {
      tests = flattenTests "" entry.artifact.passthru.tests;
    };
}
