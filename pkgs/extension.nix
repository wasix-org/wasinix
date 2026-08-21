{loadPackageOverlays}: let
  overlays = loadPackageOverlays {
    shared = ./shared;
    native = ./native;
    wasix = ./wasix;
    python = {
      directory = ./python;
      expose = map (entry: entry.attr) (import ./python/wheels/default.nix);
      definition = {
        file = ./python/wheels/default.nix;
        directory = ./python/wheels;
      };
    };
  };
in {
  id = "wasinix";

  inherit overlays;

  history = {
    wasix = ./wasix/history.json;
    python = ./python/history.json;
  };
}
