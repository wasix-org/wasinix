# Import every module installed by an otherwise-untested dependency of a
# shipped wheel. The containing wheel supplies the runtime context.
{
  lib,
  python3,
  testLib,
  wheelList,
}: let
  inherit (testLib) runPython;

  shippedEntries = lib.filter (e: python3.pkgs ? ${e.attr}) wheelList;
  shipped = map (e: python3.pkgs.${e.attr}) shippedEntries;

  worklist = map (e: e.attr) wheelList;

  normalize = n: lib.toLower (lib.replaceStrings ["_" "."] ["-" "-"] n);

  # closure minus the packages the worklist already tests, minus python itself
  members = lib.filter (
    d: let
      n = d.pname or d.name or "";
    in
      n
      != ""
      && !(lib.elem n worklist)
      && !(lib.hasPrefix "python3" n)
      && d ? dist
  ) (python3.pkgs.requiredPythonModules shipped);

  importTest = drv: let
    name = drv.pname or drv.name;
    rootEntry =
      lib.findFirst
      (candidate:
        lib.any
        (d: toString d == toString drv)
        (python3.pkgs.requiredPythonModules [python3.pkgs.${candidate.attr}]))
      (throw "no shipped wheel contains closure member ${name}")
      shippedEntries;
    root = python3.pkgs.${rootEntry.attr};
    rootImports =
      if rootEntry ? pyImport
      then lib.splitString ", " rootEntry.pyImport
      else root.pythonImportsCheck or [lib.replaceStrings ["-"] ["_"] rootEntry.attr];
  in
    runPython {
      name = "closure-import-${name}";
      wheel = root;
      # The script skips __init__-less data dirs and private helpers, which are
      # not importable on their own.
      script = ''
        import importlib, pathlib, sys

        want = ${builtins.toJSON (normalize name)}
        for root_import in ${builtins.toJSON rootImports}:
            importlib.import_module(root_import)

        def norm(s):
            return s.lower().replace("_", "-").replace(".", "-")

        site = pathlib.Path("/site")
        dists = [d for d in site.glob("*.dist-info")
                 if norm(d.name.rsplit("-", 2)[0]) == want]
        if not dists:
            raise SystemExit(f"no .dist-info for {want} in the site dir")

        tops = set()
        for d in dists:
            record = d / "RECORD"
            if not record.exists():
                continue
            for line in record.read_text().splitlines():
                p = line.split(",")[0]
                if not p or p.startswith(".."):
                    continue
                top = p.split("/")[0]
                if top.endswith((".dist-info", ".data", ".pth")):
                    continue
                if top.endswith(".py"):
                    tops.add(top[:-3])
                elif "." not in top:
                    tops.add(top)

        tops = {t for t in tops if not t.startswith("_") or (site / t).exists()}
        if not tops:
            print(f"{want}: no importable top-level module")
        for t in sorted(tops):
            print("import", t)
            importlib.import_module(t)
      '';
    };
in
  lib.listToAttrs (map (d: lib.nameValuePair (d.pname or d.name) (importTest d)) members)
