# The shipped Python wheels + import smoke-tests. Exposes each wheel in
# overlay/python-packages/wheels.nix as pythonWheels.<attr> (the wasm cross build) and
# `.tests` (named leaves plus `.all`) for targeted builds and flat
# `checks.wheel-<py>-<attr>-<test>` CI projections.
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
  # the shared check machinery (pkgs/emulated-check.nix, pkgs/lib/check-output.nix)
  emulatedChecks,
  installCheckOutputArgsIf,
  # Which worklist entries this call builds. noarch wheels (python-version-independent: they ship
  # no python code, e.g. a redistributed binary) build once on the default python; everything else
  # builds per interpreter. See pkgs/default.nix.
  select ? (_: true),
  # This call's key in the pythonWheels set ("py313"/"py314"/"noarch"); history entries gate on it.
  pyKey,
}: let
  testLib = import ./python-test-lib.nix {inherit pkgs lib python3 pythonWebc wasmer;};

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
  # Prefer an explicit import, then nixpkgs' imports, then the normalized attr
  # name. Explicit imports can select a compiled implementation.
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

  inherit (testLib) runPython;

  # `import <mod>` smoke-test: the runtime counterpart to the static
  # `self-contained` guard below.
  importTest = name: e: wheel:
    runPython {
      name = "wheel-import-${name}";
      inherit wheel;
      script = "import ${pyImportOf e wheel}";
    };

  # Runtime store paths break bare pip targets. Metadata, shebangs, and
  # sanitized build paths do not become runtime references.
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

  # Static guard on the published metadata: pip resolves a wheel through its
  # Requires-Dist, but `import` above runs off the installed closure, so a
  # requirement naming something the registry cannot serve fails only for the
  # user. The registry serves the closure, so every requirement must name a
  # member of it that builds a wheel.
  # The same served set pythonRegistry publishes (python-registry/default.nix):
  # a requirement may be met by another entry or its closure, as snowflake's
  # boto3 is, without appearing in the requiring wheel's own. Names only, so
  # this stays a string input rather than a dependency on every wheel.
  servedNames = let
    entries = map (e: python3.pkgs.${e.attr}) (lib.filter (e: lib.elem pyKey (e.variants or allVariants)) wheelList);
  in
    lib.unique (map (m: m.pname or m.name)
      (lib.filter (m: m ? dist) (entries ++ python3.pkgs.requiredPythonModules entries)));

  depsTest = name: wheel: let
    checker = pkgs.python3.withPackages (ps: [ps.packaging]);
  in
    pkgs.runCommand "wheel-deps-${name}" {} ''
      ${checker.interpreter} ${./python-wheel-deps.py} \
        ${wheel.dist} ${python3.pythonVersion} \
        ${lib.escapeShellArgs servedNames} > "$out"
    '';

  # Static guard on the loader's view: a PIC extension resolves what it does not
  # define through GOT imports, and wasm-ld makes an undefined symbol one of
  # those rather than failing the link, so a missing library builds cleanly and
  # breaks only when wasmer loads the module (google-re2 shipped that way
  # against abseil). Require something the loader will have to export each one.
  dynamicTest = name: wheel: let
    members = lib.filter (m: m ? dist) ([wheel] ++ python3.pkgs.requiredPythonModules [wheel]);
    sites = map (m: "${m}/${python3.sitePackages}") members;
  in
    pkgs.runCommand "wheel-dynamic-${name}" {} ''
      ${pkgs.python3.interpreter} ${./python-wheel-dyn.py} \
        ${python3}/bin/python${python3.pythonVersion}.wasm \
        ${lib.escapeShellArgs sites} > "$out"
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

  # A history entry's served version must match the version in its wheel
  # filename, which some build systems derive independently from src.
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

  # Package tests follow overlay/python-packages/<attr>/tests/*.nix and return
  # named derivations from the supplied scope.
  pkgTestsDir = attr: ./overlay/python-packages + "/${attr}/tests";
  pkgTests = e: let
    dir = pkgTestsDir e.attr;
    scope = {
      wheel = python3.pkgs.${e.attr};
      # for `deps` (test-only wheels: pytest plugins, fixture libs)
      pythonPkgs = python3.pkgs;
      inherit runPython pkgs lib;
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
  inherit (import ./python-publish.nix {inherit pkgs lib;}) publishOf;
  mkWheel = name: e: wheel: let
    historyVersion =
      if name == e.attr
      then null
      else lib.removePrefix "${e.attr}-" name;
    variants =
      if historyVersion == null
      then e.variants or allVariants
      else historyTable.${e.attr}.${historyVersion}.variants or ["py313" "py314"];
    # Read declarations from the native package because cross finalAttrs recurse.
    nativeWheel = pkgs.python3Packages.${e.attr} or null;
    # Map native Python check inputs back into this interpreter's cross package
    # set.
    guestFromNative = inputs:
      lib.filter (d: d != null) (map (
          d: let
            candidate = builtins.tryEval (
              let
                inputName = d.pname or (lib.getName d);
                attr =
                  {
                    "pytest-check-hook" = "pytestCheckHook";
                    "unittest-check-hook" = "unittestCheckHook";
                  }.${
                    inputName
                  }
                  or inputName;
              in
                if builtins.hasAttr attr python3.pkgs
                then python3.pkgs.${attr}
                else null
            );
          in
            if candidate.success
            then candidate.value
            else null
        )
        (lib.filter (d: d != null) inputs));
    nativeDeclared =
      if nativeWheel == null
      then []
      else
        (nativeWheel.overrideAttrs (old: {
          passthru =
            (old.passthru or {})
            // {
              wasixOriginalCheckInputs =
                (old.nativeCheckInputs or [])
                ++ (old.nativeInstallCheckInputs or []);
            };
        })).wasixOriginalCheckInputs;
    explicitCheckInputs = wheel.wasixDeclaredCheckInputs or null;
    selectedCheckInputs =
      if explicitCheckInputs != null
      then explicitCheckInputs
      else guestFromNative nativeDeclared;
    hasCustomInstallCheck =
      nativeWheel
      != null
      && (nativeWheel.drvAttrs.installCheckPhase or null) != null;
    hasCheckHook = lib.any (d: lib.hasInfix "check-hook" (lib.getName d)) selectedCheckInputs;
    # passthru.wasix.installCheck overrides per package; true is the only way
    # to run a suite nixpkgs does not run.
    declaredHere = ((wheel.passthru or {}).wasix or {}).installCheck or null;
    wantsInstallCheck =
      if declaredHere != null
      then declaredHere
      else hasCustomInstallCheck || hasCheckHook;
    # Input to the emulated check only, never the shipped artifact: the extra
    # output changes the derivation, splitting the package from the copy
    # dependents resolve, which the registry rejects as conflicting wheels.
    withCheck = wheel.overrideAttrs (old:
      (installCheckOutputArgsIf wantsInstallCheck old)
      // lib.optionalAttrs wantsInstallCheck {
        # The snapshot retains the build environment. Apply reference checks
        # only to the outputs that ship.
        __structuredAttrs = true;
        disallowedReferences = [];
        outputChecks = lib.genAttrs (old.outputs or ["out"]) (output: let
          checks = (old.outputChecks or {}).${output} or {};
        in
          checks
          // {
            disallowedReferences = (old.disallowedReferences or []) ++ (checks.disallowedReferences or []);
          });
      });
    checkSpec = ((wheel.passthru or {}).wasix or {}).emulatedCheck or {};
    shardCount = checkSpec.shards or 1;
    mkDerivedUpstream = shard:
      emulatedChecks.checkFor {
        drv = withCheck;
        # timeout / expectFail / broken, same declaration the C side uses
        spec = removeAttrs checkSpec ["shards"];
        phase = "pythonCheckPhase";
        # The runner, every check input, and the TRANSITIVE closure of both:
        # PYTHONPATH does no propagation, so a plugin's own dependencies must
        # be named too or their imports fail in the guest.
        guestInputs = let
          evalOk = d: d != null && (builtins.tryEval (builtins.seq d.drvPath true)).success;
          guestUsable = d: d ? pythonModule || lib.hasInfix "check-hook" (lib.getName d);
          declared = lib.filter evalOk selectedCheckInputs;
          # Keep the declared input when its propagated closure cannot
          # evaluate. The check then fails if it imports the missing module.
          closureFor = d: let
            attempted = builtins.tryEval (
              let
                modules = python3.pkgs.requiredPythonModules [d];
              in
                builtins.seq (builtins.length modules) modules
            );
          in
            if attempted.success
            then attempted.value
            else [];
        in
          lib.unique (declared ++ lib.filter (d: evalOk d && guestUsable d) (lib.concatMap closureFor (lib.filter guestUsable declared)));
        name = "wheel-${name}" + lib.optionalString (shard != null) "-upstream-${toString shard}-of-${toString shardCount}";
        postRestore = lib.optionalString (shard != null) ''
          export WASIX_CHECK_SHARD_COUNT=${toString shardCount}
          export WASIX_CHECK_SHARD_NUM=${toString shard}
        '';
      };
    derivedUpstream =
      lib.throwIf (!(builtins.isInt shardCount && shardCount > 0))
      "wheel-${name}: emulatedCheck.shards must be a positive integer"
      (
        if !(withCheck ? check)
        then {}
        else if shardCount == 1
        then {upstream = mkDerivedUpstream null;}
        else
          # Split large suites into cacheable CI leaves that share the captured tree.
          lib.listToAttrs (lib.genList (
              shard:
                lib.nameValuePair
                "upstream-${toString shard}-of-${toString shardCount}"
                (mkDerivedUpstream shard)
            )
            shardCount)
      );
  in
    wheel.overrideAttrs (o: {
      passthru =
        removeAttrs (o.passthru or {}) ["tests"]
        // {
          # The interpreters this entry is built for, and the publishable form
          # that states them. overrideAttrs only adds passthru, so the wheel
          # publishOf reads is the same store path either way.
          wasix = (o.passthru.wasix or {}) // {inherit variants;};
          published = publishOf {
            drv = wheel;
            inherit variants;
          };
          publishedWith = suffix:
            publishOf {
              drv = wheel;
              inherit variants suffix;
            };
          # `skipTest` marks a wheel that cannot be imported on its own, so it
          # gates the tests that run one; the static guards read the artifact
          # and apply to every wheel.
          tests = mkTestGroup "wheel-${name}" ({
              behavior =
                {
                  self-contained = selfContainedTest name wheel;
                  deps = depsTest name wheel;
                  dynamic = dynamicTest name wheel;
                }
                // lib.optionalAttrs (e.noarch or false) {noarch-closure = noarchClosureTest name wheel;}
                // lib.optionalAttrs (!(e.skipTest or false)) ({
                    import = importTest name e wheel;
                  }
                  // lib.optionalAttrs (historyVersion != null) {version = versionTest name historyVersion wheel;}
                  // lib.optionalAttrs (name == e.attr && builtins.pathExists (pkgTestsDir e.attr)) (pkgTests e));
            }
            // lib.optionalAttrs (name == e.attr) derivedUpstream);
        };
    });

  # History wheels (<attr>-<version>): the entry's older releases, minted in the
  # python set as <attr>_<version> by rebasing the src (load-packages.nix history,
  # driven by python-packages/history.json). Never noarch. `spec.variants` is the
  # generic history gate (see load-packages.nix): the build variants an entry is
  # limited to; for this set a variant IS an interpreter (pyKey), default both.
  # A worklist entry reads the same `variants` gate as a history entry, for a
  # package one interpreter cannot run (cramjam's pyo3 predates 3.14).
  allVariants = ["py313" "py314" "noarch"];

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
      (lib.filter (e: select e && lib.elem pyKey (e.variants or allVariants)) wheelList)
    )))
