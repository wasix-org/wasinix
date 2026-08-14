"""Extract a package version's public Python API surface from its wheel.

Downloads the wheel into memory, AST-parses every public module and records the
exported names, so two versions can be diffed without executing anything.
"""

import ast, gzip, io, json, os, sys, urllib.request, zipfile
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
APIDIR = f"{HERE}/../cache/api"
os.makedirs(APIDIR, exist_ok=True)

SKIP_PARTS = {
    "tests",
    "test",
    "testing",
    "_vendor",
    "vendored",
    "conftest",
    "benchmarks",
}
MAX_BYTES = 40 * 1024 * 1024


def public(n):
    return not n.startswith("_")


def module_name(path):
    parts = path[:-3].split("/")
    if parts[-1] == "__init__":
        parts = parts[:-1]
    return parts


def literal_all(tree):
    for node in tree.body:
        if isinstance(node, ast.Assign):
            for t in node.targets:
                if isinstance(t, ast.Name) and t.id == "__all__":
                    try:
                        v = ast.literal_eval(node.value)
                        return [x for x in v if isinstance(x, str)]
                    except (ValueError, SyntaxError):
                        return None
    return None


def sig(node):
    a = node.args
    names = [x.arg for x in a.posonlyargs + a.args + a.kwonlyargs]
    return ",".join(names) + ("|*" if a.vararg else "") + ("|**" if a.kwarg else "")


def scan_module(src, mod):
    """Return {qualname: signature-or-empty} for the public API of one module."""
    try:
        tree = ast.parse(src)
    except (SyntaxError, ValueError):
        return {}
    out = {}
    exported = literal_all(tree)
    allow = set(exported) if exported is not None else None

    def keep(name):
        return public(name) and (allow is None or name in allow)

    for node in tree.body:
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            if keep(node.name):
                out[node.name] = sig(node)
        elif isinstance(node, ast.ClassDef):
            if not keep(node.name):
                continue
            out[node.name] = ""
            for sub in node.body:
                if isinstance(sub, (ast.FunctionDef, ast.AsyncFunctionDef)) and (
                    public(sub.name) or sub.name in ("__init__", "__call__")
                ):
                    out[f"{node.name}.{sub.name}"] = sig(sub)
                elif isinstance(sub, ast.Assign):
                    for t in sub.targets:
                        if isinstance(t, ast.Name) and public(t.id):
                            out[f"{node.name}.{t.id}"] = ""
                elif (
                    isinstance(sub, ast.AnnAssign)
                    and isinstance(sub.target, ast.Name)
                    and public(sub.target.id)
                ):
                    out[f"{node.name}.{sub.target.id}"] = ""
        elif isinstance(node, (ast.Assign, ast.AnnAssign)):
            targets = node.targets if isinstance(node, ast.Assign) else [node.target]
            for t in targets:
                if isinstance(t, ast.Name) and keep(t.id):
                    out.setdefault(t.id, "")
        elif isinstance(node, ast.ImportFrom):
            # `from .submodule import Thing` re-exports; an absolute import pulls in
            # machinery such as `from typing import Tuple` or `from __future__ import ...`
            for al in node.names:
                name = al.asname or al.name
                if name == "*":
                    continue
                if (node.level or (allow and name in allow)) and keep(name):
                    out.setdefault(name, "")
        elif isinstance(node, ast.Import):
            for al in node.names:
                name = al.asname or al.name.split(".")[0]
                if allow and name in allow and keep(name):
                    out.setdefault(name, "")
    # names re-exported through __all__ but produced dynamically still count
    if allow:
        for name in allow:
            if public(name):
                out.setdefault(name, "")
    return out


def extract(url):
    req = urllib.request.Request(url, headers={"User-Agent": "wasinix-version-survey"})
    with urllib.request.urlopen(req, timeout=300) as r:
        blob = r.read(MAX_BYTES + 1)
    if len(blob) > MAX_BYTES:
        raise RuntimeError("wheel too large")
    zf = zipfile.ZipFile(io.BytesIO(blob))
    api, root_api, roots, n_py, n_ext = {}, {}, set(), 0, 0
    for info in zf.infolist():
        name = info.filename
        if name.endswith((".so", ".pyd", ".dylib")):
            n_ext += 1
        if not name.endswith(".py"):
            continue
        parts = module_name(name)
        if not parts or parts[0].endswith((".dist-info", ".data")):
            continue
        if any(p in SKIP_PARTS or p.startswith("_") for p in parts):
            continue
        roots.add(parts[0])
        n_py += 1
        try:
            src = zf.read(info)
        except (RuntimeError, zipfile.BadZipFile):
            continue
        mod = ".".join(parts)
        names = scan_module(src, mod)
        for k, v in names.items():
            api[f"{mod}:{k}"] = v
        if len(parts) == 1 and name.endswith("__init__.py"):
            root_api.update(names)
    return {
        "api": api,
        "root": root_api,
        "roots": sorted(roots),
        "n_py": n_py,
        "n_ext": n_ext,
    }


def path_for(project, version):
    safe = version.replace("/", "_")
    return f"{APIDIR}/{project}@{safe}.json.gz"


def fetch_one(job):
    project, version, url = job
    p = path_for(project, version)
    if os.path.exists(p):
        return project, version, None
    try:
        r = extract(url)
    except Exception as ex:
        r = {"error": f"{type(ex).__name__}: {ex}"}
    with gzip.open(p, "wt") as fh:
        json.dump(r, fh)
    return project, version, r.get("error")


def main(jobs):
    errs = []
    with ThreadPoolExecutor(12) as ex:
        for i, (p, v, err) in enumerate(ex.map(fetch_one, jobs), 1):
            if err:
                errs.append((p, v, err))
            if i % 100 == 0:
                print(f"  {i}/{len(jobs)}", file=sys.stderr)
    return errs


if __name__ == "__main__":
    main(json.load(open(sys.argv[1])))
