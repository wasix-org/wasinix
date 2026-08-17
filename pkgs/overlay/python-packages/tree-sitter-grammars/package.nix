# tree-sitter grammars PyPI ships but nixpkgs does not package. Each is a
# generated parser.c plus a setuptools binding over the core, so they share one
# builder. Sources come from the tag: most sdists drop the vendored
# src/tree_sitter/parser.h and the external scanner, which builds a parser whose
# scanner symbols are missing at load. swift generates its parser sources during
# release, so it has none in the repo and uses the sdist instead.
let
  grammars = {
    c = {
      version = "0.24.2";
      hash = "sha256-Juuf57GQI7OAP6O03KtSzyKJAoXtGKjyYJ+sTM1A4mU=";
      owner = "tree-sitter";
    };
    cpp = {
      version = "0.23.4";
      hash = "sha256-tP5Tu747V8QMCEBYwOEmMQUm8OjojpJdlRmjcJTbe2k=";
      owner = "tree-sitter";
    };
    css = {
      version = "0.25.0";
      hash = "sha256-jFsnEyS+FThk7L48FzAdSp5fNPSLvM8hTL/VC5FMlOE=";
      owner = "tree-sitter";
    };
    elixir = {
      version = "0.3.5";
      hash = "sha256-C5/+t49pcFh45GqLZRjRs/sH8Ej+dklR/brad+snsyQ=";
      owner = "elixir-lang";
    };
    fortran = {
      version = "0.6.0";
      hash = "sha256-je9RlV/KozBGcCrOeFLC0f3LZ0avxZIn3nAiHzrWIoI=";
      owner = "stadelmanma";
    };
    go = {
      version = "0.25.0";
      hash = "sha256-y7bTET8ypPczPnMVlCaiZuswcA7vFrDOc2jlbfVk5Sk=";
      owner = "tree-sitter";
    };
    groovy = {
      version = "0.1.2";
      hash = "sha256-usgT3dOq5Tg1wet4jCcS47Dn+2psl7dPRjcimjZClBk=";
      owner = "amaanq";
    };
    java = {
      version = "0.23.5";
      hash = "sha256-OvEO1BLZLjP3jt4gar18kiXderksFKO0WFXDQqGLRIY=";
      owner = "tree-sitter";
    };
    julia = {
      version = "0.23.1";
      hash = "sha256-jwtMgHYSa9/kcsqyEUBrxC+U955zFZHVQ4N4iogiIHY=";
      owner = "tree-sitter";
    };
    kotlin = {
      version = "1.1.0";
      hash = "sha256-6jjK5rA/lEdsYDboU7wGfzEiRdZo44SrLlcgWci0xa4=";
      owner = "tree-sitter-grammars";
    };
    lua = {
      version = "0.5.0";
      hash = "sha256-VzaaN5pj7jMAb/u1fyyH6XmLI+yJpsTlkwpLReTlFNY=";
      owner = "tree-sitter-grammars";
    };
    objc = {
      version = "3.0.2";
      hash = "sha256-aK8Cf8F05NzlXnYS47jPjSyouaajsr1H+vRg2aXsPrs=";
      owner = "tree-sitter-grammars";
    };
    php = {
      version = "0.24.1";
      hash = "sha256-SUoWvPnNpgg5QMxbTw7XfXEoxyOkqnNFPnrMZnoiJH0=";
      owner = "tree-sitter";
    };
    powershell = {
      version = "0.26.4";
      hash = "sha256-3mOHt5lWEv8G8EmaeXcquVO+Jo3ot2tVG62El3eVMBU=";
      owner = "airbus-cert";
    };
    regex = {
      version = "0.25.0";
      hash = "sha256-bR0K6SR19QuQwDUic+CJ69VQTSGqry5a5IOpPTVJFlo=";
      owner = "tree-sitter";
    };
    scala = {
      version = "0.26.2";
      hash = "sha256-PRyNcsiGeGfKtHvbLaGtiog/P8QEs117rqoBZZOXbeE=";
      owner = "tree-sitter";
    };
    swift = {
      version = "0.7.3";
      hash = "sha256-qH8dujBQo0buNEKq2Ncnr9dFVd6iWOMccceTTYwEr5s=";
    };
    toml = {
      version = "0.7.0";
      hash = "sha256-m9RlGkHiOL/PNENrdEPqtPlahSqGymsx7gZrCoN/Lsk=";
      owner = "tree-sitter-grammars";
    };
    typescript = {
      version = "0.23.2";
      hash = "sha256-CU55+YoFJb6zWbJnbd38B7iEGkhukSVpBN7sli6GkGY=";
      owner = "tree-sitter";
    };
    verilog = {
      version = "1.0.3";
      hash = "sha256-SlK33WQhutIeCXAEFpvWbQAwOwMab68WD3LRIqPiaNY=";
      owner = "tree-sitter";
    };
    xml = {
      version = "0.7.0";
      hash = "sha256-/0IQsTkvFQOWnkLc2srjg2bn1sB1sNA6Sm3nwKGUDj4=";
      owner = "tree-sitter-grammars";
    };
    zig = {
      version = "1.1.2";
      hash = "sha256-lDMmnmeGr2ti9W692ZqySWObzSUa9vY7f+oHZiE8N+U=";
      owner = "tree-sitter-grammars";
    };
  };
in {
  names = map (lang: "tree-sitter-${lang}") (builtins.attrNames grammars);
  packages = {
    pyfinal,
    final,
    ...
  }: let
    updater = final.buildPackages.writeShellApplication {
      name = "update-tree-sitter-grammars";
      runtimeInputs = with final.buildPackages; [curl git gnused jq nix];
      text = builtins.readFile ./update.sh;
    };
  in
    builtins.listToAttrs (map (lang: let
      spec = grammars.${lang};
    in {
      name = "tree-sitter-${lang}";
      value = pyfinal.buildPythonPackage {
        pname = "tree-sitter-${lang}";
        inherit (spec) version;
        pyproject = true;

        src =
          if spec ? owner
          then
            final.fetchFromGitHub {
              inherit (spec) owner hash;
              repo = "tree-sitter-${lang}";
              tag = "v${spec.version}";
            }
          else
            pyfinal.fetchPypi {
              pname = "tree_sitter_${lang}";
              inherit (spec) version hash;
            };

        build-system = [pyfinal.setuptools];

        pythonImportsCheck = ["tree_sitter_${lang}"];

        passthru.updateScript = ["${updater}/bin/update-tree-sitter-grammars" lang];
      };
    }) (builtins.attrNames grammars));
}
