# get_context('fork') must fail up front on wasix (no os.fork); a context
# that only breaks inside Process.start() is not acceptable.
import multiprocessing as mp
import sys

methods = mp.get_all_start_methods()
if methods != ["spawn"]:
    print(f"MPCTX_FAIL: get_all_start_methods() -> {methods}")
    sys.exit(1)
try:
    mp.get_context("fork")
except ValueError:
    pass
else:
    print("MPCTX_FAIL: get_context('fork') did not raise ValueError")
    sys.exit(1)
print("MPCTX_OK")
