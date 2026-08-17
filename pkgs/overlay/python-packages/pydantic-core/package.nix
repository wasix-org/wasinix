{
  pyprev,
  pyfinal,
  helpers,
  lib,
  ...
}: let
  pytest8CheckHook = pyfinal.pytestCheckHook.override {pytest = pyfinal.pytest_8_3;};
in
  helpers.libTweaks ({
      maturinBuildFlags = ["--features" "pyo3/extension-module"];
      patches = lib.optionals (lib.versionAtLeast pyprev.pydantic-core.version "2.46") [
        ./patches/wasm-function-recursion.patch
      ];
      passthru.wasixDeclaredCheckInputs = [
        pytest8CheckHook
        pyfinal.hypothesis
        pyfinal.inline-snapshot
        pyfinal.pytest-timeout
        pyfinal.dirty-equals
        pyfinal.pytest-benchmark
        pyfinal.pytest-mock
        pyfinal.pytest-run-parallel
        pyfinal.typing-inspection
      ];
      preCheck = ''
        export PYTHONPATH="${pyfinal.pytest_8_3}/${pyfinal.python.sitePackages}:$PYTHONPATH"
      '';
    }
    // lib.optionalAttrs (lib.versionOlder pyprev.pydantic-core.version "2.42") {
      sourceRoot = "source";
    })
  pyprev.pydantic-core
