{
  exposeExtendedPackage,
  packages,
  package,
  lib,
}: let
  pytest8CheckHook = packages.sameProfile.pytestCheckHook.override {pytest = packages.sameProfile.pytest_8_3;};
in
  exposeExtendedPackage ({
      maturinBuildFlags = ["--features" "pyo3/extension-module"];
      patches = lib.optionals (lib.versionAtLeast package.version "2.46") [
        ./patches/wasm-function-recursion.patch
      ];
      passthru.wasixDeclaredCheckInputs = [
        pytest8CheckHook
        packages.sameProfile.hypothesis
        packages.sameProfile.inline-snapshot
        packages.sameProfile.pytest-timeout
        packages.sameProfile.dirty-equals
        packages.sameProfile.pytest-benchmark
        packages.sameProfile.pytest-mock
        packages.sameProfile.pytest-run-parallel
        packages.sameProfile.typing-inspection
      ];
      preCheck = ''
        export PYTHONPATH="${packages.sameProfile.pytest_8_3}/${packages.sameProfile.python.sitePackages}:$PYTHONPATH"
      '';
    }
    // lib.optionalAttrs (lib.versionOlder package.version "2.42") {
      sourceRoot = "source";
    })
