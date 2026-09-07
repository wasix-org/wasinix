# Extensions in the wheel index are named for the interpreter's SOABI, and the
# cross builds that produce them read the sysconfigdata module named for MACHDEP
# and MULTIARCH. Both come from CPython's platform triplet, which resolves to
# wasm32-wasi-threads whenever the compiler defines _REENTRANT.
import sys
import sysconfig

tag = "cpython-%d%d-wasm32-wasi" % sys.version_info[:2]
expected = {
    "SOABI": tag,
    "EXT_SUFFIX": f".{tag}.so",
    "MULTIARCH": "wasm32-wasi",
    "MACHDEP": "wasix",
}

failed = False
for var, want in expected.items():
    got = sysconfig.get_config_var(var)
    if got != want:
        print(f"SOABI_FAIL: {var} is {got!r}, expected {want!r}")
        failed = True
if failed:
    sys.exit(1)
print("SOABI_OK")
