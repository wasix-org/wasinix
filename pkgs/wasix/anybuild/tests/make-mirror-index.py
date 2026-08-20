#!/usr/bin/env python3
"""Lay the pinned PyPI files out as a PEP 503 "simple" index.

    make-mirror-index.py <dists.json> <out>

<dists.json> is [{project, version, files: [{filename, path, sha256}]}], the
lock's dists with each file already fetched to a store path.
"""

import json
import re
import shutil
import sys
from pathlib import Path

dists_path, out = Path(sys.argv[1]), Path(sys.argv[2])
dists = json.loads(dists_path.read_text())

projects: dict[str, list[dict]] = {}
for dist in dists:
    name = re.sub(r"[-_.]+", "-", dist["project"]).lower()
    projects.setdefault(name, []).extend(dist["files"])

(out / "simple").mkdir(parents=True)
for project, files in sorted(projects.items()):
    packages = out / "packages" / project
    packages.mkdir(parents=True)
    links = []
    for entry in sorted(files, key=lambda entry: entry["filename"]):
        shutil.copyfile(entry["path"], packages / entry["filename"])
        href = f"../../packages/{project}/{entry['filename']}#sha256={entry['sha256']}"
        links.append(f'<a href="{href}">{entry["filename"]}</a><br/>')
    (out / "simple" / project).mkdir()
    (out / "simple" / project / "index.html").write_text(
        "<!DOCTYPE html><html><body>\n" + "\n".join(links) + "\n</body></html>\n"
    )

roots = "\n".join(f'<a href="{name}/">{name}</a><br/>' for name in sorted(projects))
(out / "simple" / "index.html").write_text(
    "<!DOCTYPE html><html><body>\n" + roots + "\n</body></html>\n"
)
print(f"{len(projects)} projects, {sum(len(f) for f in projects.values())} files")
