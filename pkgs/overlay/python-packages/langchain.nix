# langchain for wasix. nixpkgs' postPatch bakes a bash store path into
# langchain/agents/middleware/shell_tool.py; spliced to our target that is a
# wasm bash, which only builds in the off profile, so the whole wheel fails to
# build. The library doesn't import shell_tool (it's an optional shell-command
# agent tool), so drop the substitution and keep the literal "/bin/bash" (a
# guest path, mounted at runtime if the tool is ever used).
{pyprev, ...}:
pyprev.langchain.overridePythonAttrs (_: {
  postPatch = "";
})
