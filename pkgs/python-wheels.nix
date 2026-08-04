# The shipped Python wheels + import smoke-tests. Exposes each wheel in
# overlay/python-packages/wheels.nix as pythonWheels.<attr> (the wasm cross build) and
# .tests (an import run under wasmer), for `.#pythonWheels.<attr>` targets + checks.wheel-<attr>.
{
  pkgs,
  lib,
  # the wasix cpython at its ehpic profile (drives the wheel closure + version).
  python3,
  # the self-contained python webc; the interpreter it bundles runs the import
  # test with no host /nix/store.
  pythonWebc,
  # wasmer runtime for the smoke-tests (flake input; null -> pkgs.wasmer).
  wasmer ? null,
  mkTestGroup,
  # Which worklist entries this call builds. noarch wheels (python-version-independent: they ship
  # no python code, e.g. a redistributed binary) build once on the default python; everything else
  # builds per interpreter. See pkgs/default.nix.
  select ? (_: true),
  # This call's key in the pythonWheels set ("py313"/"py314"/"noarch"); history entries gate on it.
  pyKey,
}: let
  effWasmer =
    if wasmer != null
    then wasmer
    else pkgs.wasmer;

  wheelList = import ./overlay/python-packages/wheels.nix;
  # Older releases also served (registry history), keyed by worklist attr then version;
  # JSON so scripts/history.py and update.py can edit it (schema: see wheels.nix header).
  historyTable = builtins.fromJSON (builtins.readFile ./overlay/python-packages/history.json);
  unknownHistory = lib.filter (n: !(lib.elem n (map (e: e.attr) wheelList))) (lib.attrNames historyTable);
  # A noarch entry builds once on the default python, so its history versions
  # would be gated out by every `variants` value and silently never ship.
  noarchHistory =
    map (e: e.attr)
    (lib.filter (e: (e.noarch or false) && historyTable ? ${e.attr}) wheelList);
  # Import target: nixpkgs' own pythonImportsCheck names the real module, and
  # often a compiled submodule too; the attr with '-' -> '_' is the guess for
  # the packages nixpkgs sets none on. An explicit pyImport still wins, which is
  # how an entry reaches a compiled module nixpkgs' list would let fall back to
  # a pure impl (pyyaml, protobuf), or skips one wasix can't run (watchdog).
  pyImportOf = e: wheel:
    e.pyImport
    or (
      let
        ic = wheel.pythonImportsCheck or [];
      in
        if ic != []
        then lib.concatStringsSep ", " ic
        else lib.replaceStrings ["-"] ["_"] e.attr
    );

  # Run a python `script` on the SELF-CONTAINED python webc with the wheel + its
  # dep closure copied into a plain (non-store) dir and NO /nix/store mounted -- as
  # `pip install --target` then a run would on a bare wasix target. A wheel that
  # reaches an unmounted store path (a ctypes .so, a spawned binary) fails here, as
  # it would under real pip. Only HOME is writable (some wheels resolve a config dir
  # at import, e.g. matplotlib.get_configdir). The script fails the check by raising;
  # the trailing marker confirms it ran through. Shared by the import smoke-test and
  # the per-package tests/ (see mkWheel).
  runPython = {
    name,
    wheel,
    script,
  }: let
    pythonPath = python3.pkgs.makePythonPath [wheel];
    marker = "PYRUN_OK ${name}";
    file = pkgs.writeText "${name}.py" ''
      ${script}
      print(${builtins.toJSON marker})
    '';
  in
    pkgs.runCommand name {
      nativeBuildInputs = [effWasmer];
    } ''
      export HOME=$TMPDIR/home
      mkdir -p "$HOME"
      webc=$(${pkgs.findutils}/bin/find ${pythonWebc} -name '*.webc' | head -1)

      site=$TMPDIR/site
      mkdir -p "$site"
      IFS=: read -ra _paths <<< ${lib.escapeShellArg pythonPath}
      for p in "''${_paths[@]}"; do
        [ -d "$p" ] && ${pkgs.rsync}/bin/rsync -a --chmod=u+w "$p"/ "$site"/
      done
      cp ${file} "$site/__pyrun__.py"

      log=$(mktemp)
      # stdin from /dev/null: a guest that touches a socket makes wasmer prompt for
      # the networking capability, and the prompt blocks until the 600s timeout kills
      # it, losing python's buffered stdout (ddtrace imports such a socket).
      if timeout 600 wasmer run \
        --volume "$site":/site \
        --mapdir /home:"$HOME" \
        --env HOME=/home \
        --env PYTHONPATH=/site \
        "$webc" -- /site/__pyrun__.py >"$log" 2>&1 </dev/null \
        && ${pkgs.gnugrep}/bin/grep -q ${lib.escapeShellArg marker} "$log"; then
        cp "$log" "$out"
      else
        echo "python test '${name}' failed (no /nix/store, pip-like):" >&2
        cat "$log" >&2
        exit 1
      fi
    '';

  # `import <mod>` smoke-test: the runtime counterpart to the static
  # `self-contained` guard below.
  importTest = name: e: wheel:
    runPython {
      name = "wheel-import-${name}";
      inherit wheel;
      script = "import ${pyImportOf e wheel}";
    };

  # Static guard: a wheel must not bake a /nix/store path it loads at runtime
  # (ctypes/cffi .so, a spawned binary) - that path won't exist on a bare wasix
  # pip target, so the wheel would import/run only under a store mount. Bundle
  # the artifact instead (overlay/python-packages/lib/bundle.nix). Excludes, as
  # non-runtime: .dist-info metadata (provenance), line-1 shebangs (a lib is
  # never exec'd), and the eeee-sanitized build paths recorded by some configs.
  selfContainedTest = name: wheel:
    pkgs.runCommand "wheel-selfcontained-${name}" {} ''
      site="${wheel}/${python3.sitePackages}"
      hits=$(${pkgs.gnugrep}/bin/grep -rnaE '/nix/store/[a-z0-9]{32}-' "$site" --include='*.py' \
        | ${pkgs.gnugrep}/bin/grep -vE '\.dist-info/' \
        | ${pkgs.gnugrep}/bin/grep -vE ':1:#!' \
        | ${pkgs.gnugrep}/bin/grep -v 'eeeeeeeeeeeeeeee' || true)
      if [ -n "$hits" ]; then
        echo "wheel '${name}' embeds runtime /nix/store paths (breaks pip on a bare wasix target):" >&2
        echo "$hits" >&2
        echo "-> bundle the artifact into the wheel, see overlay/python-packages/lib/bundle.nix" >&2
        exit 1
      fi
      echo "OK ${name}" > "$out"
    '';

  # Guards a `noarch` mark (a python-version-independent package, e.g. a redistributed binary): the
  # wheel AND its whole python-dep closure must be py3-none-any. A version-specific (cp-tagged)
  # member builds only on the default python, so the other interpreter can't resolve it from the
  # merged registry. Runs on the default python.
  noarchClosureTest = name: wheel: let
    members = lib.filter (m: m ? dist) ([wheel] ++ python3.pkgs.requiredPythonModules [wheel]);
  in
    pkgs.runCommand "wheel-noarch-closure-${name}" {} ''
      fail=
      for dist in ${lib.escapeShellArgs (map (m: "${m.dist}") members)}; do
        whl=$(${pkgs.findutils}/bin/find "$dist" -name '*.whl' | head -1)
        case "$(basename "$whl")" in
          *-py3-none-any.whl | *-py2.py3-none-any.whl) ;;
          *)
            echo "noarch '${name}': closure member $(basename "$whl") is version-specific" >&2
            fail=1
            ;;
        esac
      done
      if [ -n "$fail" ]; then
        echo "-> a noarch wheel's whole closure must be py3-none-any; make the dep noarch or drop the mark." >&2
        exit 1
      fi
      echo "OK ${name}: closure all py3-none-any" > "$out"
    '';

  # A history wheel is served under its entry's version, but the artifact's
  # version comes from the build, and not every build takes it from the src
  # (pandas derives it via versioneer, which cannot recover it from a tarball
  # with no git, so it silently keeps nixpkgs'). Serving that hands a resolver
  # asking for one version a wheel claiming another. Current wheels need no
  # such check: their version IS the one the build derives.
  versionTest = name: version: wheel:
    pkgs.runCommand "wheel-version-${name}" {} ''
      whl=$(${pkgs.findutils}/bin/find "${wheel.dist}" -name '*.whl' | head -1)
      base=$(basename "$whl")
      got=''${base#*-}
      got=''${got%%-*}
      if [ "$got" != "${version}" ]; then
        echo "wheel '${name}' is served as ${version} but its artifact is $got ($base)" >&2
        echo "-> the build does not take its version from the rebased src; set it in the package file" >&2
        exit 1
      fi
      echo "OK ${name}: artifact is $got" > "$out"
    '';

  # Per-package behavioural tests: overlay/python-packages/<attr>/tests/*.nix, each
  # a function over a subset of {wheel, runPython, lib} returning named test
  # derivations, folded into the wheel's test group -- the wheel analogue of the
  # wasmer packages/<name>/tests/ convention.
  pkgTestsDir = attr: ./overlay/python-packages + "/${attr}/tests";
  pkgTests = e: let
    dir = pkgTestsDir e.attr;
    scope = {
      wheel = python3.pkgs.${e.attr};
      inherit runPython lib;
    };
  in
    builtins.foldl' (
      acc: fname: let
        f = import (dir + "/${fname}");
      in
        acc // f (builtins.intersectAttrs (lib.functionArgs f) scope)
    ) {}
    (lib.attrNames (lib.filterAttrs
      (n: t: t == "regular" && lib.hasSuffix ".nix" n && n != "helpers.nix")
      (builtins.readDir dir)));

  # The wheel drv with .tests added (passthru-only, so the store path is
  # unchanged). Inherited nixpkgs passthru.tests are dropped: they are x86 test
  # suites that would leak into `checks`. Per-package tests/ run only on the
  # primary (current) wheel (name == e.attr), not history versions.
  mkWheel = name: e: wheel: let
    historyVersion =
      if name == e.attr
      then null
      else lib.removePrefix "${e.attr}-" name;
  in
    wheel.overrideAttrs (o: {
      passthru =
        removeAttrs (o.passthru or {}) ["tests"]
        // lib.optionalAttrs (!(e.skipTest or false)) {
          tests = mkTestGroup "wheel-${name}" ({
              import = importTest name e wheel;
              self-contained = selfContainedTest name wheel;
            }
            // lib.optionalAttrs (historyVersion != null) {version = versionTest name historyVersion wheel;}
            // lib.optionalAttrs (e.noarch or false) {noarch-closure = noarchClosureTest name wheel;}
            // lib.optionalAttrs (name == e.attr && builtins.pathExists (pkgTestsDir e.attr)) (pkgTests e));
        };
    });

  # History wheels (<attr>-<version>): the entry's older releases, minted in the
  # python set as <attr>_<version> by rebasing the src (load-packages.nix history,
  # driven by python-packages/history.json). Never noarch. `spec.variants` is the
  # generic history gate (see load-packages.nix): the build variants an entry is
  # limited to; for this set a variant IS an interpreter (pyKey), default both.
  historyUnder = v: lib.replaceStrings ["."] ["_"] v;
  historyOf = e:
    lib.concatMap (
      v: let
        spec = historyTable.${e.attr}.${v};
        name = "${e.attr}-${v}";
      in
        lib.optionals (lib.elem pyKey (spec.variants or ["py313" "py314"])) [
          (lib.nameValuePair name (mkWheel name e python3.pkgs."${e.attr}_${historyUnder v}"))
        ]
    ) (lib.attrNames (historyTable.${e.attr} or {}));
in
  lib.throwIf (unknownHistory != [])
  "history.json: not in the wheels.nix worklist: ${lib.concatStringsSep ", " unknownHistory}"
  (lib.throwIf (noarchHistory != [])
    "history.json: noarch entries cannot carry history versions: ${lib.concatStringsSep ", " noarchHistory}"
    (lib.listToAttrs (
      lib.concatMap
      (e: [(lib.nameValuePair e.attr (mkWheel e.attr e python3.pkgs.${e.attr}))] ++ historyOf e)
      (lib.filter select wheelList)
    )))
