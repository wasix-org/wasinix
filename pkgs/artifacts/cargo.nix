{
  lib,
  mkCargoRegistry,
}: {
  cargoRegistry = {entry, ...}:
    lib.optionalAttrs (
      entry.kind
      == "package"
      && entry.scope == "native"
      && entry.name == "cargo-registry"
      && entry.instance.kind == "current"
    ) {
      artifacts.registry = mkCargoRegistry;
    };
}
