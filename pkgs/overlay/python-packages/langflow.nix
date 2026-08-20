{
  final,
  nix-update-script,
  pyfinal,
  ...
}:
pyfinal.buildPythonPackage (finalAttrs: {
  pname = "langflow";
  version = "1.11.2";
  pyproject = true;

  src = final.fetchFromGitHub {
    owner = "langflow-ai";
    repo = "langflow";
    tag = "v${finalAttrs.version}";
    hash = "sha256-ebDaUsVbAKZOkoY3SkJbUOJqFY/3U/tjT9yR9FUcsSg=";
  };

  postPatch = ''
    substituteInPlace pyproject.toml \
      --replace-fail '"langflow-base[complete]>=0.11.2",' '"langflow-base>=0.11.2",'
  '';

  pythonRemoveDeps = [
    "lfx-amazon"
    "lfx-anthropic"
    "lfx-arxiv"
    "lfx-bundles"
    "lfx-cohere"
    "lfx-datastax"
    "lfx-docling"
    "lfx-duckduckgo"
    "lfx-empiriolabs"
    "lfx-exa"
    "lfx-firecrawl"
    "lfx-ibm"
    "lfx-nextplaid"
    "lfx-openai"
    "lfx-openai-compatible"
    "lfx-oracle"
    "lfx-paddle"
    "lfx-valkey"
    "lfx-vllm"
  ];

  build-system = [pyfinal.hatchling];
  dependencies = [pyfinal.langflow-base];

  pythonImportsCheck = ["langflow"];

  passthru.updateScript = nix-update-script {extraArgs = ["--flake"];};
  passthru.wasix.updateNotes = [
    {message = "langflow: coordinate langflow, langflow-base, and lfx versions when updating.";}
    {message = "langflow: recheck the removed lfx provider bundles on bump.";}
  ];
})
