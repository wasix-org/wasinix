{loadPackageOverlays}: let
  overlays = loadPackageOverlays {
    packages = {
      directory = ../overlays;
      lane = "packages";
    };
    python = {
      directory = ../python-overlays;
      lane = "python";
      expose = map (entry: entry.attr) (import ../python/wheels/default.nix);
      definition = {
        file = ../python/wheels/default.nix;
        directory = ../python/wheels;
      };
    };
  };
in {
  id = "wasinix";

  inherit overlays;

  history = {
    wasix = ../overlays/history.json;
    python = ../python-overlays/history.json;
  };
}
