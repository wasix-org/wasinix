{
  nix-update-script,
  pyfinal,
  ...
}:
pyfinal.buildPythonPackage rec {
  pname = "lfx";
  version = "1.11.2";
  format = "wheel";

  src = pyfinal.fetchPypi {
    inherit pname version format;
    dist = "py3";
    python = "py3";
    hash = "sha256-E+GV5mu03+h6qyngnYfguvXieB/uosxjysa0CrKSnWE=";
  };

  # The pinned set intentionally follows newer compatible releases than the
  # bounds in Langflow's coordinated uv lock.
  pythonRelaxDeps = true;
  pythonRemoveDeps = ["markitdown"];
  dependencies = with pyfinal; [
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

  passthru.updateScript = nix-update-script {extraArgs = ["--flake"];};
  passthru.wasix.updateNotes = [
    {message = "lfx: recheck markitdown once pypdfium2 supports WASIX source builds.";}
  ];
}
