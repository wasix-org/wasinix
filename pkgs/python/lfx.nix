{
  exposePackage,
  packages,
  pkgs,
}:
exposePackage (
  packages.sameProfile.buildPythonPackage rec {
    pname = "lfx";
    version = "1.11.4";
    format = "wheel";

    src = packages.sameProfile.fetchPypi {
      inherit pname version format;
      dist = "py3";
      python = "py3";
      hash = "sha256-tMUCuNDANZnZ+lkzrBsYbpRQ5hxLKMlCQOpFmWRWBdk=";
    };

    # The pinned set intentionally follows newer compatible releases than the
    # bounds in Langflow's coordinated uv lock.
    pythonRelaxDeps = true;
    pythonRemoveDeps = ["markitdown"];
    dependencies = with packages.sameProfile; [
      a2wsgi
      ag-ui-protocol
      aiofile
      aiofiles
      asyncer
      beautifulsoup4
      cachetools
      chardet
      cryptography
      defusedxml
      docstring-parser
      emoji
      fastapi
      filelock
      gunicorn
      httpx
      json-repair
      langchain
      langchain-classic
      langchain-core
      langflow-sdk
      loguru
      mcp
      nanoid
      networkx
      openpyxl
      orjson
      pandas
      passlib
      pillow
      platformdirs
      psutil
      pydantic
      pydantic-settings
      pyjwt
      pypdf
      python-dotenv
      pyyaml
      rich
      setuptools
      structlog
      toml
      tomli
      typer
      typing-extensions
      uvicorn
      validators
      wheel
    ];

    pythonImportsCheck = ["lfx"];

    passthru.updateScript = pkgs.buildPackages.nix-update-script {extraArgs = ["--flake"];};
    passthru.wasinix.update.notes = [
      {message = "lfx: recheck markitdown once pypdfium2 supports WASIX source builds.";}
    ];
  }
)
