# Registry integrity and resolution tests. Host pip installs with WASIX tags;
# imports run through the shipped Python WebC command.
{
  pkgs,
  lib,
  registry,
  harnesses,
  # eval-only (version tags).
  python3,
  pythonCommand,
  testLib,
}: let
  hostPython = pkgs.python3.withPackages (ps: [ps.pip]);
  hostPythonExe = lib.getExe hostPython;
  pyVersion = python3.pythonVersion;
  guestPython = pythonCommand.name;

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
  forwardEnv = harnesses.defaultForwardEnv ++ ["PYTHONPATH"];

  fakeRclone = pkgs.writeShellScript "fake-rclone" ''
    printf '%s\n' "$*" >> "$FAKE_RCLONE_LOG"
    operation="$6"
    if [ "$operation" = copy ] && [ "$7" = test:bucket/manifests ]; then
      exit 3
    fi
    if [ "$operation" = copy ]; then
      source="''${@: -2:1}"
      cp -r "$source/." "$FAKE_CAPTURE/"
    fi
    exit 0
  '';

  # pip-install <attr> from the index, assert expectDeps (top-level module/dir
  # names) were resolved along, then import <pyImport> on the shipped python.
  resolveTest = {
    attr,
    pyImport ? attr,
    expectDeps ? [],
  }:
    harnesses.hostShell {
      name = "registry-resolve-${attr}";
      hostPackages = [hostPython];
      wasixCommands = [pythonCommand];
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
      native=native-1.0+wasix.1-cp313-none-wasix_wasm32.whl
      pure=pure-1.0+wasix.1-py3-none-any.whl
      mkdir -p registry/simple/native registry/simple/pure capture
      printf native > "registry/simple/native/$native"
      printf 'Metadata-Version: 2.1\n' > "registry/simple/native/$native.metadata"
      printf pure > "registry/simple/pure/$pure"
      printf 'Metadata-Version: 2.1\n' > "registry/simple/pure/$pure.metadata"
      printf '<a href="native/">native</a>\n' > registry/simple/index.html
      printf '<a href="$native">native</a>\n' > registry/simple/native/index.html
      cat > registry/provenance.json <<EOF
      {
        "$native": {"attr": "native", "drv_path": "/nix/store/native", "name": "native", "rel_key": "native", "version": "1.0"},
        "$pure": {"attr": "pure", "drv_path": "/nix/store/pure", "name": "pure", "rel_key": "pure", "version": "1.0"}
      }
      EOF
      export FAKE_RCLONE_LOG="$PWD/rclone.log"
      export FAKE_CAPTURE="$PWD/capture"
      python3 ${./.}/publish.py \
        --registry registry \
        --remote test:bucket \
        --rclone ${fakeRclone} \
        --refresh-listings \
        --dry-run
      grep -F 'copy test:bucket/manifests' "$FAKE_RCLONE_LOG"
      test -f "capture/simple/native/$native"
      test -f "capture/manifests/$native.json"
      test ! -e capture/all
      test ! -e capture/simple/pure
      test ! -e "capture/manifests/$pure.json"
      grep -F "$native" capture/packages.json
      ! grep -F "$pure" capture/packages.json
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
  http-index = harnesses.hostShell {
    name = "registry-http-index";
    hostPackages = [hostPython];
    wasixCommands = [pythonCommand];
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
  e2e-project = harnesses.hostShell {
    name = "registry-e2e-project";
    hostPackages = [hostPython];
    wasixCommands = [pythonCommand];
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
