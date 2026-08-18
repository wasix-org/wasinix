# anybuild's python templates built end to end against wasinix's own indexes,
# with no network beyond loopback: the wasix overlay (.#pythonRegistry) as the
# extra index and the pinned PyPI mirror (helpers.nix) as the primary one.
#
# Native anybuild, not the wasix build: the cross-wheel steps run uv and uvx on
# the build host, and there is no uv for wasix. The covered templates are
# mirror-lock.json's `templates`, which is also what the mirror is resolved
# from, so the two cannot drift.
#
# The template sweep runs on 3.13, the version anybuild's provider pins, because
# the templates' own requirements decide what can resolve: python-flask pins
# MarkupSafe==3.0.2, which PyPI has no cp314 wheel for at all. The serve check
# runs on both, so the newer interpreter's wheels are still exercised end to end.
{
  pkgs,
  preferredProfilePackages,
  testLib,
  helpers,
  pythonRegistry,
  wasmerPackages,
}: let
  inherit (pkgs) lib;

  examples = "${pkgs.anybuild.src}/examples";

  # Templates whose install steps produce a cross-compiled site-packages: the
  # python provider serves the app off a wasix venv, while mkdocs only uses
  # python at build time and serves the generated site statically. A template
  # with no dependencies never reaches the cross-wheel steps at all.
  crossInstalled =
    builtins.filter
    (name: helpers.providers.${name} == "python" && helpers.requirements.${name} != [])
    helpers.templates;
  staticSite =
    builtins.filter (name: helpers.providers.${name} == "mkdocs") helpers.templates;

  # The template the serve check boots: a framework app whose wheels carry wasm
  # extensions, so a successful request exercises loading them.
  servedTemplate = "python-pillow";

  interpreters = {
    "3.13" = {
      host = pkgs.python313;
      webc = preferredProfilePackages.python313;
    };
    "3.14" = {
      host = pkgs.python314;
      webc = preferredProfilePackages.python314;
    };
  };

  # A webc names its dependencies but does not carry them, so the tree needs each
  # package's closure too (bash pulls coreutils).
  depTrees = pkgs': lib.concatMapStringsSep " " (p: "${p.pkg.depTree}") (lib.filter (p: p.pkg.depTree != null) pkgs');

  # anybuild resolves the app's serve-time packages by name; supplying them from
  # the store is what lets a sandboxed run work at all.
  runtimeWebcs = interpreter:
    pkgs.runCommand "anybuild-runtime-webcs-${interpreter.webc.pkg.id.name}" {} ''
      mkdir -p "$out"
      for tree in ${interpreter.webc.webc} ${wasmerPackages.bash.webc} ${depTrees [interpreter.webc wasmerPackages.bash]}; do
        cp -R --no-preserve=mode,ownership "$tree/." "$out/"
      done
    '';
  reference = pkg: "${pkg.id.owner}/${pkg.id.name}@=${pkg.id.version}";

  # anybuild's python provider pins its version through config, and uv resolves
  # the local venv against whatever interpreter it finds, so the version under
  # test is both the config and the only python on PATH.
  interpreterEnv = version: interpreter: ''
    export ANYBUILD_PYTHON_VERSION=${version}
    export ANYBUILD_WASMER_PACKAGE_PYTHON=${reference interpreter.webc.pkg}
    export ANYBUILD_WASMER_PACKAGE_BASH=${reference wasmerPackages.bash.pkg}
  '';

  # anybuild builds the wasmer invocation itself, so the local packages ride in
  # through the binary it calls. --offline turns a package we failed to supply
  # into an error instead of a registry lookup.
  wasmerLocal = interpreter: ''
    cat > wasmer-local <<EOF
    #!/bin/sh
    if [ "\$1" = run ]; then
      shift
      exec ${testLib.wasmer}/bin/wasmer run --quiet --offline --include-webc ${runtimeWebcs interpreter} "\$@"
    fi
    exec ${testLib.wasmer}/bin/wasmer "\$@"
    EOF
    chmod +x wasmer-local
    wasmer_local="$PWD/wasmer-local"
  '';

  toolsFor = interpreter: [pkgs.anybuild pkgs.uv interpreter.host pkgs.bash pkgs.curl testLib.wasmer];

  expectations = version:
    pkgs.writeText "anybuild-cross-install-${version}.json" (builtins.toJSON {
      pythonVersion = version;
      inherit crossInstalled staticSite;
    });

  buildTest = version: interpreter:
    testLib.mkScriptRun {
      name = "anybuild-python-templates-${version}";
      packages = toolsFor interpreter;
      timeout = 5400;
      script = ''
        ${helpers.serveIndexes pythonRegistry}
        ${interpreterEnv version interpreter}

        for name in ${toString helpers.templates}; do
          echo "=== $name"
          cp -R "${examples}/$name" "$name"
          chmod -R u+w "$name"
          # A committed uv.lock records absolute files.pythonhosted.org URLs, so
          # `uv sync --locked` reaches past any mirror by construction. Dropping it
          # takes the plain `uv sync` branch, which resolves against the served
          # index; the lock's own pins are in the mirror, so the versions match.
          rm -f "$name/uv.lock"
          ( cd "$name" && anybuild build . --wasmer --skip-prepare )
        done

        python3 ${./check-cross-install.py} ${expectations version} .
        echo "ok: ${toString (builtins.length helpers.templates)} templates built on python ${version}"
      '';
    };

  # The built app actually runs: anybuild boots it under wasmer and it answers a
  # request. Its serve-time packages come from the store rather than the
  # registry, which is also the only way it can load our wheels at all (the
  # pinned python/python is built without threads; see WASIX-TODO.md).
  serveTest = version: interpreter:
    testLib.mkScriptRun {
      name = "anybuild-python-template-serve-${version}";
      packages = toolsFor interpreter;
      timeout = 1800;
      script = ''
        ${helpers.serveIndexes pythonRegistry}
        ${interpreterEnv version interpreter}
        ${wasmerLocal interpreter}

        cp -R "${examples}/${servedTemplate}" app
        chmod -R u+w app
        cd app
        anybuild build . --wasmer --skip-prepare --wasmer-bin "$wasmer_local"

        # anybuild runs the app with --forward-host-env, so the build host's python
        # environment reaches the guest interpreter and its sysconfig lookup dies on
        # _sysconfigdata__linux_x86_64-linux-gnu.
        env -u _PYTHON_SYSCONFIGDATA_NAME -u _PYTHON_HOST_PLATFORM -u PYTHONPATH -u PYTHONHOME \
          anybuild run . --start --wasmer --wasmer-bin "$wasmer_local" &
        trap 'kill %1 %2 %3 2>/dev/null || true' EXIT

        for _ in $(seq 1 120); do
          curl -fsS -o response.html http://127.0.0.1:8080/ && break
          sleep 2
        done
        curl -fsS -o response.html http://127.0.0.1:8080/ \
          || { echo "anybuild: ${servedTemplate} never served a page" >&2; exit 1; }
        test -s response.html
        echo "ok: ${servedTemplate} served a page on python ${version}"
      '';
    };
  sweepVersion = "3.13";
in
  {python-templates = buildTest sweepVersion interpreters.${sweepVersion};}
  // lib.mapAttrs' (version: interpreter:
    lib.nameValuePair "serve-${version}" (serveTest version interpreter))
  interpreters
