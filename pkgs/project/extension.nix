{loadPackageOverlays}: let
  overlays = loadPackageOverlays {
    packages = {
      directory = ../overlays;
      definition = {
        file = ./extension.nix;
        directory = null;
      };
      inherited = {
        brotli = {};
        bzip2 = {};
        editline = {};
        expat = {};
        giflib = {};
        jansson = {};
        lcms2 = {};
        libb2 = {};
        libblake3 = {};
        libdeflate = {};

        # WASIX libc provides iconv; keep the nixpkgs shim rather than GNU libiconv.
        # The shim ships no archive because the symbols live in libc.
        libiconv = {};

        libyaml = {};
        lz4 = {};
        mpfr = {};

        # nix uses nlohmann_json for JSON handling.
        nlohmann_json = {};

        oniguruma = {};
        openjpeg = {};
        popt = {};
        tinyxml-2 = {};

        # nix uses toml11 for TOML parsing.
        toml11 = {};

        xz = {};
      };
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
