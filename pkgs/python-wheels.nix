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
}: let
  effWasmer =
    if wasmer != null
    then wasmer
    else pkgs.wasmer;

  wheelList = import ./overlay/python-packages/wheels.nix;
  pyImportOf = e: e.pyImport or (lib.replaceStrings ["-"] ["_"] e.attr);

  # Smoke-test `import <mod>` the way `pip install` runs on a bare wasix target:
  # the wheel + its python dep closure are copied into a plain (non-store) dir,
  # then imported on the SELF-CONTAINED python webc with only that dir + HOME
  # mounted and NO /nix/store. A wheel that needs an unmounted store path (a
  # ctypes .so, a spawned binary) fails here, as it would under real pip. This
  # is the runtime counterpart to the static `self-contained` guard below.
  importTest = e: let
    wheel = python3.pkgs.${e.attr};
    # colon-joined site-packages of the wheel + all transitive python deps.
    pythonPath = python3.pkgs.makePythonPath [wheel];
    mod = pyImportOf e;
  in
    pkgs.runCommand "wheel-import-${e.attr}" {
      nativeBuildInputs = [effWasmer];
    } ''
      export HOME=$TMPDIR/home
      mkdir -p "$HOME"
      webc=$(${pkgs.findutils}/bin/find ${pythonWebc} -name '*.webc' | head -1)

      # flatten the closure into one plain dir, as `pip install --target` would.
      site=$TMPDIR/site
      mkdir -p "$site"
      IFS=: read -ra _paths <<< ${lib.escapeShellArg pythonPath}
      for p in "''${_paths[@]}"; do
        [ -d "$p" ] && ${pkgs.rsync}/bin/rsync -a --chmod=u+w "$p"/ "$site"/
      done

      log=$(mktemp)
      # Mount only the plain site dir + a writable HOME (some wheels resolve a
      # config/cache dir at import, e.g. matplotlib.get_configdir). No /nix/store:
      # the webc is self-contained, and any store path the wheel still reaches for
      # is absent, so this fails exactly as a bare pip install would.
      if timeout 600 wasmer run \
        --volume "$site":/site \
        --mapdir /home:"$HOME" \
        --env HOME=/home \
        --env PYTHONPATH=/site \
        "$webc" -- \
        -c 'import ${mod}; print("WHEEL_IMPORT_OK ${mod}")' >"$log" 2>&1; then
        if ${pkgs.gnugrep}/bin/grep -q "WHEEL_IMPORT_OK ${mod}" "$log"; then
          cp "$log" "$out"
        else
          echo "import ${mod} did not confirm OK for wheel '${e.attr}':" >&2
          cat "$log" >&2
          exit 1
        fi
      else
        echo "wasmer run failed importing ${mod} (wheel '${e.attr}', no /nix/store - pip-like):" >&2
        cat "$log" >&2
        exit 1
      fi
    '';

  # Static guard: a wheel must not bake a /nix/store path it loads at runtime
  # (ctypes/cffi .so, a spawned binary) - that path won't exist on a bare wasix
  # pip target, so the wheel would import/run only under a store mount. Bundle
  # the artifact instead (overlay/python-packages/lib/bundle.nix). Excludes, as
  # non-runtime: .dist-info metadata (provenance), line-1 shebangs (a lib is
  # never exec'd), and the eeee-sanitized build paths recorded by some configs.
  selfContainedTest = e: let
    wheel = python3.pkgs.${e.attr};
  in
    pkgs.runCommand "wheel-selfcontained-${e.attr}" {} ''
      site="${wheel}/${python3.sitePackages}"
      hits=$(${pkgs.gnugrep}/bin/grep -rnaE '/nix/store/[a-z0-9]{32}-' "$site" --include='*.py' \
        | ${pkgs.gnugrep}/bin/grep -vE '\.dist-info/' \
        | ${pkgs.gnugrep}/bin/grep -vE ':1:#!' \
        | ${pkgs.gnugrep}/bin/grep -v 'eeeeeeeeeeeeeeee' || true)
      if [ -n "$hits" ]; then
        echo "wheel '${e.attr}' embeds runtime /nix/store paths (breaks pip on a bare wasix target):" >&2
        echo "$hits" >&2
        echo "-> bundle the artifact into the wheel, see overlay/python-packages/lib/bundle.nix" >&2
        exit 1
      fi
      echo "OK ${e.attr}" > "$out"
    '';

  # Guards a `noarch` mark (a python-version-independent package, e.g. a redistributed binary): the
  # wheel AND its whole python-dep closure must be py3-none-any. A version-specific (cp-tagged)
  # member builds only on the default python, so the other interpreter can't resolve it from the
  # merged registry. Runs on the default python.
  noarchClosureTest = e: let
    wheel = python3.pkgs.${e.attr};
    members = lib.filter (m: m ? dist) ([wheel] ++ python3.pkgs.requiredPythonModules [wheel]);
  in
    pkgs.runCommand "wheel-noarch-closure-${e.attr}" {} ''
      fail=
      for dist in ${lib.escapeShellArgs (map (m: "${m.dist}") members)}; do
        whl=$(${pkgs.findutils}/bin/find "$dist" -name '*.whl' | head -1)
        case "$(basename "$whl")" in
          *-py3-none-any.whl | *-py2.py3-none-any.whl) ;;
          *)
            echo "noarch '${e.attr}': closure member $(basename "$whl") is version-specific" >&2
            fail=1
            ;;
        esac
      done
      if [ -n "$fail" ]; then
        echo "-> a noarch wheel's whole closure must be py3-none-any; make the dep noarch or drop the mark." >&2
        exit 1
      fi
      echo "OK ${e.attr}: closure all py3-none-any" > "$out"
    '';

  # python3.pkgs.<attr> with .tests added (passthru-only, so the store path is
  # unchanged). Inherited nixpkgs passthru.tests are dropped: they are x86 test
  # suites that would leak into `checks`.
  mkWheel = e:
    (python3.pkgs.${e.attr}).overrideAttrs (o: {
      passthru =
        removeAttrs (o.passthru or {}) ["tests"]
        // lib.optionalAttrs (!(e.skipTest or false)) {
          tests = mkTestGroup "wheel-${e.attr}" ({
              import = importTest e;
              self-contained = selfContainedTest e;
            }
            // lib.optionalAttrs (e.noarch or false) {noarch-closure = noarchClosureTest e;});
        };
    });
in
  lib.listToAttrs (map (e: lib.nameValuePair e.attr (mkWheel e)) (lib.filter select wheelList))
