# spawnv_passfds a child with pipe write ends placed at the fd numbers given
# in argv; the child must write b"ok" back through each. Exercises the dup2
# bounce in multiprocessing-posix-spawn-wasi*.patch, whose tmp slots (128+i)
# collide with passed fds in [128, 128+len).
import os
import sys
from multiprocessing.util import spawnv_passfds

targets = [int(a) for a in sys.argv[1:]]
readers = {}
for target in targets:
    r, w = os.pipe()
    if w != target:
        os.dup2(w, target)
        os.close(w)
    readers[target] = r

child = "import os, sys\nfor a in sys.argv[1:]:\n    os.write(int(a), b'ok')\n"
argv = [sys.executable, "-c", child] + [str(t) for t in targets]
pid = spawnv_passfds(sys.executable, argv, targets)
for target in targets:
    os.close(target)

code = os.waitstatus_to_exitcode(os.waitpid(pid, 0)[1])
failures = []
if code != 0:
    failures.append(f"child exit code {code}")
for target, r in readers.items():
    data = os.read(r, 2)
    if data != b"ok":
        failures.append(f"fd {target}: got {data!r}")
if failures:
    print("PASSFDS_FAIL:", "; ".join(failures))
    sys.exit(1)
print("PASSFDS_OK", *targets)
