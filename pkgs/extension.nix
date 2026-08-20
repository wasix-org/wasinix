{loadPackageOverlays}: {
  id = "wasinix";

  overlays = loadPackageOverlays {
    shared = ./shared;
    native = ./native;
    wasix = ./wasix;
    python = ./python;
  };

  history = {
    wasix = ./wasix/history.json;
    python = ./python/history.json;
  };
}
