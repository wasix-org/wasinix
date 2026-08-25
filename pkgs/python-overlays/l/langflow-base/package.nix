{
  exposePackage,
  packages,
  pkgs,
}:
exposePackage (
  packages.sameProfile.buildPythonPackage (finalAttrs: {
    pname = "langflow-base";
    version = "0.11.4";
    format = "wheel";

    # The release wheel carries the built Vite frontend. The tagged source does
    # not, and rebuilding it would introduce a Node toolchain into this Python
    # wheel's cross build.
    src = packages.sameProfile.fetchPypi {
      pname = "langflow_base";
      inherit (finalAttrs) version;
      format = "wheel";
      dist = "py3";
      python = "py3";
      hash = "sha256-KCyaImTyVPz4vdrQAiLf8PtdK/XxoBBleN4o83dQVME=";
    };

    # The wheel hook repacks dependency metadata after patchPhase. Patch the
    # resulting wheel before installation so the bundled frontend stays intact.
    preInstall = ''
      wheelFile=$(find dist -name '*.whl' -print -quit)
      unpacked=$TMPDIR/langflow-a2a-patch
      mkdir "$unpacked"
      ${packages.sameProfile.lib.getExe packages.sameProfile.python.pythonOnBuildForHost.pkgs.wheel} unpack --dest "$unpacked" "$wheelFile"
      packageRoot="$unpacked/langflow_base-${finalAttrs.version}"
      patch -d "$packageRoot" -p1 < ${./langflow-base-optional-routes.patch}
      mv "$wheelFile" "$TMPDIR/langflow-base-original.whl"
      ${packages.sameProfile.lib.getExe packages.sameProfile.python.pythonOnBuildForHost.pkgs.wheel} pack --dest dist "$packageRoot"
    '';

    pythonRelaxDeps = true;
    # Keep the core server and UI independent of provider-specific SDKs. A2A and
    # OTLP pull the unported C++ gRPC closure through Google protocol packages;
    # runtime pip installs cannot produce WASIX wheels inside the application.
    pythonRemoveDeps = [
      "a2a-sdk"
      "assemblyai"
      "ibm-watsonx-ai"
      "jsonquerylang"
      "langchain-chroma"
      "langchain-experimental"
      "langchain-ibm"
      "langchain-mongodb"
      "langchain-qdrant"
      "langchain-weaviate"
      "langchainhub"
      "opentelemetry-exporter-otlp"
      "pip"
      "spider-client"
      "trustcall"
      "uncurl"
    ];

    dependencies = with packages.sameProfile; [
      ag-ui-protocol
      aiofile
      aiofiles
      aiosqlite
      alembic
      asyncer
      bcrypt
      cachetools
      chardet
      clickhouse-connect
      cryptography
      defusedxml
      docstring-parser
      duckdb
      dynaconf
      elevenlabs
      email-validator
      emoji
      fastapi
      fastapi-pagination
      filelock
      grandalf
      greenlet
      gunicorn
      httpx
      jaraco-context
      jq
      json-repair
      langchain
      langchain-community
      langchain-core
      langchain-perplexity
      langflow-sdk
      langgraph-checkpoint
      lfx
      loguru
      mcp
      multiprocess
      nanoid
      nest-asyncio
      networkx
      onnxruntime
      opentelemetry-api
      opentelemetry-exporter-prometheus
      opentelemetry-instrumentation-fastapi
      opentelemetry-instrumentation-requests
      opentelemetry-instrumentation-urllib3
      opentelemetry-sdk
      orjson
      pandas
      passlib
      pillow
      platformdirs
      prometheus-client
      pyasn1
      pydantic
      pydantic-settings
      pyjwt
      pypdf
      pyperclip
      python-docx
      python-multipart
      rich
      scipy
      sentry-sdk
      setuptools
      slowapi
      sqlalchemy
      sqlmodel
      structlog
      transformers
      typer
      uvicorn
      validators
      wheel
    ];

    pythonImportsCheck = ["langflow"];

    passthru.updateScript = pkgs.buildPackages.nix-update-script {extraArgs = ["--flake"];};
    passthru.wasinix.update.notes = [
      {message = "langflow-base: verify that the release wheel still contains the built frontend.";}
      {message = "langflow-base: recheck the removed provider integrations on bump.";}
      {message = "langflow-base: recheck the optional A2A, knowledge-base, and memory routes on bump.";}
    ];
  })
)
