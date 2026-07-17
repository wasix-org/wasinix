# find_library must pick the highest dylib version, not the longest
# filename. The fakes only need the header ctypes' dylink.0 sniffer reads:
# wasm magic + version, custom-section id, section-length LEB, name.
import ctypes.util
import os
import sys

FAKE_DYLINK = b"\x00asm\x01\x00\x00\x00\x00\x09\x08dylink.0"
libs = os.path.abspath("libs")
os.makedirs(libs, exist_ok=True)
for name in ("libvertest.so.9.1", "libvertest.so.10"):
    with open(os.path.join(libs, name), "wb") as f:
        f.write(FAKE_DYLINK)

os.environ["LD_LIBRARY_PATH"] = libs
got = ctypes.util.find_library("vertest")
if got != "libvertest.so.10":
    print(f"FINDLIB_FAIL: picked {got!r}, expected 'libvertest.so.10'")
    sys.exit(1)
print("FINDLIB_OK")
