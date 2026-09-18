# Registry integrity and resolution tests. Host pip installs with WASIX tags;
# imports run through the shipped Python WebC command.
{
  pkgs,
  lib,
  registry,
  # the pinned pure PyPI wheels, taken beside the registry (mirror.nix).
  mirror,
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
  # The registry serves only what PyPI cannot; the mirror stands in for PyPI,
  # so a resolve reads our wheel for a native or patched project and the pinned
  # pure wheel for everything else.
  pipFlags = "${pipResolveFlags} --index-url file://${mirror}/simple --extra-index-url file://${registry}/simple";

  # PYTHONPATH is how the pip --target tree reaches the guest interpreter.
  forwardEnv = harnesses.defaultForwardEnv ++ ["PYTHONPATH"];

  # A fake rclone that additionally seeds a manifest predating the supersedes
  # field on the manifests fetch, so the relist test can prove a flag-less
  # published manifest is still listed from the current build's provenance.
  seedingRclone = pkgs.writeScript "fake-rclone-seeding" ''
    #!${pkgs.python3}/bin/python3
    import sys, os, json, hashlib, pathlib
    argv = sys.argv[1:]
    open(os.environ["FAKE_RCLONE_LOG"], "a").write(" ".join(argv) + "\n")
    if "copy" in argv:
        rest = [a for a in argv[argv.index("copy") + 1:] if not a.startswith("--")]
        src, dst = rest[0], rest[1]
        if src.endswith("/manifests"):
            d = pathlib.Path(dst)
            d.mkdir(parents=True, exist_ok=True)
            whl = pathlib.Path("registry/simple/watchdog/watchdog-1.0-py3-none-any.whl")
            sha = hashlib.sha256(whl.read_bytes()).hexdigest()
            (d / "watchdog-1.0-py3-none-any.whl.json").write_text(json.dumps(
                {"project": "watchdog", "sha256": sha, "metadata_sha256": "x",
                 "requires_python": ">=3.8", "size": 1, "published": "2026-09-14"}))
    sys.exit(0)
  '';

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

  # A pure supersedesPyPI wheel first published before the supersedes field
  # existed carries no flag in its frozen manifest. Regenerating listings from
  # the manifest alone drops it from simple/ (watchdog, uninstallable from PyPI
  # on wasix); the publisher must take the flag from the current build's
  # provenance so --refresh-listings relists it without a rel bump.
  publisher-relists-supersedes = testLib.mkScriptRun {
    name = "registry-publisher-relists-supersedes";
    packages = [pkgs.python3];
    script = ''
      mkdir -p registry/simple/watchdog
      python3 -c 'import zipfile
      md = "Metadata-Version: 2.1\nName: watchdog\nVersion: 1.0\nRequires-Python: >=3.8\n\n"
      base = "registry/simple/watchdog/watchdog-1.0-py3-none-any.whl"
      z = zipfile.ZipFile(base, "w"); z.writestr("watchdog-1.0.dist-info/METADATA", md); z.close()
      open(base + ".metadata", "w").write(md)'
      echo '{"watchdog-1.0-py3-none-any.whl": {"supersedes": true, "rel_key": "artifacts.registry.python.wheels.watchdog", "version": "1.0"}}' \
        > registry/provenance.json
      export FAKE_RCLONE_LOG="$PWD/rclone.log"
      python3 ${./.}/publish.py \
        --registry registry \
        --remote test:bucket \
        --rclone ${seedingRclone} \
        --refresh-listings
      staging=$(grep -oE 'copy --ignore-times [^ ]+' "$FAKE_RCLONE_LOG" | awk '{print $3}' | tail -1)
      test -f "$staging/simple/watchdog/index.html"
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
      ${hostPythonExe} -m http.server 8080 --bind 127.0.0.1 --directory ${mirror} &
      ${hostPythonExe} -m http.server 8081 --bind 127.0.0.1 --directory ${registry} &
      sleep 1
      ${hostPythonExe} -m pip install ${pipResolveFlags} \
        --index-url http://127.0.0.1:8080/simple \
        --extra-index-url http://127.0.0.1:8081/simple \
        --target site requests
      export PYTHONPATH="$PWD/site"
      ${guestPython} -c 'import requests; r = requests.get("http://127.0.0.1:8080/simple/", timeout=30); assert r.ok and "requests" in r.text; print("REGISTRY_HTTP_OK")' | tee net.log
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
