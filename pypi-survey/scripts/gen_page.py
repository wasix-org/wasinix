#!/usr/bin/env python3
"""Inject survey data into template.html -> artifact.html + standalone flame.html."""

import json
import os
import sys

BASE = os.path.dirname(os.path.abspath(__file__))
OUTDIR = sys.argv[1]

tpl = open(os.path.join(BASE, "template.html")).read()
page_data = open(os.path.join(OUTDIR, "data", "page_data.json")).read()
flame_data = open(os.path.join(OUTDIR, "data", "flame_view.json")).read()

html = tpl.replace("__PAGE_DATA__", page_data).replace("__FLAME_DATA__", flame_data)

with open(os.path.join(BASE, "artifact.html"), "w") as f:
    f.write(html)

title_line = "<title>PyPI native dependency survey</title>"
standalone = (
    '<!doctype html>\n<html lang="en">\n<head>\n'
    '<meta charset="utf-8">\n'
    '<meta name="viewport" content="width=device-width, initial-scale=1">\n'
    f"{title_line}\n</head>\n<body>\n"
    + html.replace(title_line, "", 1)
    + "\n</body>\n</html>\n"
)
with open(os.path.join(OUTDIR, "flame.html"), "w") as f:
    f.write(standalone)

# extract the script for a node syntax check
script = html.split("<script>")[1].split("</script>")[0]
with open(os.path.join(BASE, "check.js"), "w") as f:
    f.write(script)
print(
    "sizes: artifact=%dK standalone=%dK" % (len(html) // 1024, len(standalone) // 1024)
)
