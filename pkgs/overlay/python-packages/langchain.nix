# langchain for wasix. nixpkgs' postPatch bakes a bash store path into
# langchain/agents/middleware/shell_tool.py; spliced to our target that is a
# wasm bash, which only builds in the off profile, so the whole wheel fails to
# build. The library doesn't import shell_tool (it's an optional shell-command
# agent tool), so drop the substitution and keep the literal "/bin/bash" (a
# guest path, mounted at runtime if the tool is ever used).
#
# The monorepo kept 1.x in libs/langchain_v1 while 0.3 continued in
# libs/langchain, so an older tag has 1.0 alphas under the sourceRoot nixpkgs
# names and builds a wheel with the wrong version. 0.3 also caps
# langchain-core<1 and needs text-splitters and SQLAlchemy, which 1.x dropped.
{
  pyprev,
  pyfinal,
  helpers,
  lib,
  ...
}:
helpers.libTweaks ({
    postPatch = _: "";
    disabledTestPaths = [
      "tests/unit_tests/agents/middleware/implementations/test_shell_tool.py"
      "tests/unit_tests/agents/middleware/implementations/test_shell_execution_policies.py"
    ];
    passthru.wasinix.checks.captured.install = false;
  }
  // lib.optionalAttrs (lib.versionOlder pyprev.langchain.version "1") {
    sourceRoot = "source/libs/langchain";
    propagatedBuildInputs = ps:
      helpers.replaceInputsByName {
        langchain-core = pyfinal.langchain-core_0_3_86;
      }
      ps
      ++ [
        pyfinal.langchain-text-splitters_0_3_11
        pyfinal.sqlalchemy
      ];
  })
pyprev.langchain
