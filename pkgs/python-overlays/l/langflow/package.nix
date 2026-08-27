{
  exposePackage,
  packages,
  pkgs,
}:
exposePackage (
  packages.sameProfile.buildPythonPackage (finalAttrs: {
    pname = "langflow";
    version = "1.12.0";
    pyproject = true;

    src = pkgs.fetchFromGitHub {
      owner = "langflow-ai";
      repo = "langflow";
      tag = "v${finalAttrs.version}";
      hash = "sha256-i3lbuoHnv2qkOeYO+Tyrx+5dRwqCQxhcqkGu5epk43M=";
    };

    postPatch = ''
      substituteInPlace pyproject.toml \
        --replace-fail '"langflow-base~=1.12.0",' '"langflow-base",' \
        --replace-fail '"langflow-base[audio]~=1.12.0",' '"langflow-base[audio]",' \
        --replace-fail '"langflow-base[sandbox]~=1.12.0",' '"langflow-base[sandbox]",' \
        --replace-fail '"langflow-base[postgresql]~=1.12.0",' '"langflow-base[postgresql]",' \
        --replace-fail '"langflow-base[pgvector]~=1.12.0",' '"langflow-base[pgvector]",' \
        --replace-fail '"langflow-base[opensearch]~=1.12.0",' '"langflow-base[opensearch]",'
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

    build-system = [packages.sameProfile.hatchling];
    dependencies = [packages.sameProfile.langflow-base];

    pythonImportsCheck = ["langflow"];

    # Upstream tags every prerelease as v<x>.<y>.<z>.dev<n>; only take releases.
    passthru.updateScript = pkgs.buildPackages.nix-update-script {extraArgs = ["--flake" "--version-regex" "^v([0-9.]+)$"];};
    passthru.wasinix.update.notes = [
      {message = "langflow: coordinate langflow, langflow-base, and lfx versions when updating.";}
      {message = "langflow: recheck the removed lfx provider bundles on bump.";}
    ];
  })
)
