# pip has to install, not just import: that drives zipfile, importlib.metadata
# and the filesystem, which is where a wasix interpreter tends to give out. It
# runs in-process, so a failure here is pip's and not subprocess spawning's.
import runpy
import sys
import zipfile
from pathlib import Path

wheel = Path("dummy-1.0-py3-none-any.whl")
with zipfile.ZipFile(wheel, "w") as z:
    z.writestr("dummy/__init__.py", "VALUE = 41\n")
    z.writestr(
        "dummy-1.0.dist-info/WHEEL",
        "Wheel-Version: 1.0\nGenerator: t\nRoot-Is-Purelib: true\nTag: py3-none-any\n",
    )
    z.writestr(
        "dummy-1.0.dist-info/METADATA",
        "Metadata-Version: 2.1\nName: dummy\nVersion: 1.0\n",
    )
    z.writestr("dummy-1.0.dist-info/RECORD", "")

target = Path("site")
sys.argv = [
    "pip",
    "install",
    "--no-index",
    "--no-cache-dir",
    "--disable-pip-version-check",
    "--target",
    str(target),
    str(wheel),
]
try:
    runpy.run_module("pip", run_name="__main__")
except SystemExit as e:
    if e.code:
        print(f"PIP_FAIL: pip install exited {e.code}")
        sys.exit(1)

# read what pip laid down rather than importing it: importing after an
# in-process install is deprecated, and pip 26.3 makes it an error
mod = target / "dummy" / "__init__.py"
dist = target / "dummy-1.0.dist-info"
if not mod.is_file() or not dist.is_dir():
    print(f"PIP_FAIL: install left {sorted(p.name for p in target.iterdir())}")
    sys.exit(1)

ns = {}
exec(compile(mod.read_text(), str(mod), "exec"), ns)
if ns.get("VALUE") != 41:
    print(f"PIP_FAIL: installed module gave {ns.get('VALUE')}")
    sys.exit(1)
print("PIP_OK")
