{lib}: let
  historyMeta = ["note" "variants" "cargoHash" "vendorLayout"];

  rebasePackage = version: spec: package: let
    fetchArgs = builtins.removeAttrs spec historyMeta;
    # fetchurl has no override interface, so release tarballs replace the
    # fixed-output fields directly.
    src =
      if package.src ? override
      then package.src.override fetchArgs
      else
        package.src.overrideAttrs (_: {
          urls = [spec.url];
          outputHash = spec.hash;
          name = builtins.baseNameOf spec.url;
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
    pinned // {override = args: rebasePackage version spec (package.override args);};
in {
  inherit historyMeta rebasePackage;
}
