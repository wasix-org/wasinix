# Registry tests on the shared harness (pkgs/wasmer/test-lib.nix): an integrity
# walk over the generated index, plus resolve tests where the host pip
# cross-installs from the file:// index with wasi tags and the result runs on
# the shipped python webc via its run-by-name shim.
{
  pkgs,
  lib,
  registry,
  # eval-only (version tags).
  python3,
  # run-by-name shim of the shipped python webc.
  pythonWebc,
  testLib,
}: let
  hostPython = pkgs.python3.withPackages (ps: [ps.pip]);
  hostPythonExe = lib.getExe hostPython;
  pyVersion = python3.pythonVersion;
  guestPython = "python${pyVersion}";

  # Platform tag of the wasix wheels; if the target triple drifts, re-derive
  # from a wheel filename in the registry.
  wasiPlatform = "wasix_wasm32";

  # Resolve as if targeting wasix: wheels only, matching the wasi tags.
  pipResolveFlags = lib.concatStringsSep " " [
    "--quiet"
    "--no-cache-dir"
    "--disable-pip-version-check"
    "--platform ${wasiPlatform}"
    "--implementation cp"
    "--python-version ${pyVersion}"
    "--abi cp${lib.replaceStrings ["."] [""] pyVersion}"
    "--only-binary :all:"
  ];
  pipFlags = "${pipResolveFlags} --index-url file://${registry}/all/simple";

  # PYTHONPATH is how the pip --target tree reaches the guest interpreter.
  forwardEnv = testLib.defaultForwardEnv ++ ["PYTHONPATH"];

  fakeRclone = pkgs.writeShellScript "fake-rclone" ''
    printf '%s\n' "$*" >> "$FAKE_RCLONE_LOG"
    exit 3
  '';

  # pip-install <attr> from the index, assert expectDeps (top-level module/dir
  # names) were resolved along, then import <pyImport> on the shipped python.
  resolveTest = {
    attr,
    pyImport ? attr,
    expectDeps ? [],
  }:
    testLib.mkWasixRun {
      name = "registry-resolve-${attr}";
      nativePkgs = [hostPython];
      wasixPkgs = [pythonWebc];
      inherit forwardEnv;
      script = ''
        ${hostPythonExe} -m pip install ${pipFlags} --target site ${attr}
        for dep in ${lib.escapeShellArgs expectDeps}; do
          if [ ! -e "site/$dep" ]; then
            echo "dependency '$dep' was not resolved into the install target" >&2
            exit 1
          fi
        done
        export PYTHONPATH="$PWD/site"
        ${guestPython} -c 'import ${pyImport}; print("REGISTRY_IMPORT_OK ${pyImport}")' | tee import.log
        grep -q "REGISTRY_IMPORT_OK ${pyImport}" import.log
      '';
    };
in {
  publisher-explicit-rclone = testLib.mkScriptRun {
    name = "registry-publisher-explicit-rclone";
    packages = [pkgs.python3];
    script = ''
      mkdir registry
      echo '{}' > registry/provenance.json
      export FAKE_RCLONE_LOG="$PWD/rclone.log"
      python3 ${./.}/publish.py \
        --registry registry \
        --remote test:bucket \
        --rclone ${fakeRclone}
      grep -F 'copy test:bucket/manifests' "$FAKE_RCLONE_LOG"
    '';
  };

  integrity = testLib.mkScriptRun {
    name = "registry-integrity";
    packages = [(pkgs.python3.withPackages (ps: [ps.packaging]))];
    # check-dependencies.py carries the wasix marker environment the requirement
    # walk evaluates against; it is a path argument because nix copies each
    # script into the store on its own, losing the sibling relationship.
    script = "python3 ${./check-integrity.py} ${registry} ${../python/wheels/check-dependencies.py}";
  };

  # pure wheel with a pure dep chain.
  resolve-requests = resolveTest {
    attr = "requests";
    expectDeps = [
      "urllib3"
      "idna"
      "certifi"
      "charset_normalizer"
    ];
  };
  # C-extension wheel: pip must pick the cp/wasi-tagged wheel and its .so must
  # dynamically load under wasmer.
  resolve-numpy = resolveTest {attr = "numpy";};

  # The index served over http: pip's http path (pages + PEP 658 sidecars),
  # then a real socket round trip from the guest through requests/urllib3.
  # Plain http only; the guest python has no _ssl.
  http-index = testLib.mkWasixRun {
    name = "registry-http-index";
    nativePkgs = [hostPython];
    wasixPkgs = [pythonWebc];
    wasmerArgs = ["--net"];
    inherit forwardEnv;
    script = ''
      ${hostPythonExe} -m http.server 8080 --bind 127.0.0.1 --directory ${registry} &
      sleep 1
      ${hostPythonExe} -m pip install ${pipResolveFlags} --index-url http://127.0.0.1:8080/all/simple --target site requests
      export PYTHONPATH="$PWD/site"
      ${guestPython} -c 'import requests; r = requests.get("http://127.0.0.1:8080/all/simple/", timeout=30); assert r.ok and "requests" in r.text; print("REGISTRY_HTTP_OK")' | tee net.log
      grep -q REGISTRY_HTTP_OK net.log
    '';
  };

  # Full-stack e2e: install e2e/pyproject.toml's deps (one wheel per build tier)
  # from the registry, then e2e/main.py hard-asserts real work with each.
  e2e-project = testLib.mkWasixRun {
    name = "registry-e2e-project";
    nativePkgs = [hostPython];
    wasixPkgs = [pythonWebc];
    inherit forwardEnv;
    script = ''
      # the pyproject is the single source of the dep list
      mapfile -t deps < <(${hostPythonExe} -c '
      import tomllib
      with open("${./e2e/pyproject.toml}", "rb") as f:
          print("\n".join(tomllib.load(f)["project"]["dependencies"]))
      ')
      ${hostPythonExe} -m pip install ${pipFlags} --target site "''${deps[@]}"

      # not listed in pyproject.toml: these must arrive as transitive deps the resolver pulls from
      # the served wheels' metadata, proving the index carries usable dependency info.
      for mod in urllib3 idna certifi charset_normalizer dateutil six.py cffi pycparser; do
        if [ ! -e "site/$mod" ]; then
          echo "transitive dependency '$mod' was not resolved from the registry" >&2
          exit 1
        fi
      done

      export PYTHONPATH="$PWD/site"
      # copy the script into the mounted test dir: the guest has no /nix/store,
      # so it can't run main.py from its store path.
      cp ${./e2e/main.py} main.py
      ${guestPython} main.py | tee e2e.log
      grep -q "E2E_ALL_OK" e2e.log
    '';
  };
}
