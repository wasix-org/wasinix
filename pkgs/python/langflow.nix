{
  final,
  nix-update-script,
  pyfinal,
  ...
}:
pyfinal.buildPythonPackage (finalAttrs: {
  pname = "langflow";
  version = "1.11.4";
  pyproject = true;

  src = final.fetchFromGitHub {
    owner = "langflow-ai";
    repo = "langflow";
    tag = "v${finalAttrs.version}";
    hash = "sha256-pC1+vUNTXdeYbsJXNZarntYNLvBr4iI7bLwnfe6D9Qw=";
  };

  postPatch = ''
    substituteInPlace pyproject.toml \
      --replace-fail '"langflow-base[complete]>=0.11.4",' '"langflow-base>=0.11.4",'
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

  # Upstream tags every prerelease as v<x>.<y>.<z>.dev<n>; only take releases.
  passthru.updateScript = nix-update-script {extraArgs = ["--flake" "--version-regex" "^v([0-9.]+)$"];};
  passthru.wasix.updateNotes = [
    {message = "langflow: coordinate langflow, langflow-base, and lfx versions when updating.";}
    {message = "langflow: recheck the removed lfx provider bundles on bump.";}
  ];
})
